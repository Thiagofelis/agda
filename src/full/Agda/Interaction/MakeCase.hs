{-# LANGUAGE CPP             #-}

module Agda.Interaction.MakeCase where

import Prelude hiding (mapM, mapM_, null)
import Control.Applicative hiding (empty)
import Control.Monad hiding (mapM, mapM_, forM)
import Data.Maybe
import Data.Traversable

import Agda.Syntax.Common
import Agda.Syntax.Position
import qualified Agda.Syntax.Concrete as C
import qualified Agda.Syntax.Abstract as A
import qualified Agda.Syntax.Info as A
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern
import Agda.Syntax.Scope.Monad (resolveName, ResolvedName(..))
import Agda.Syntax.Translation.ConcreteToAbstract
import Agda.Syntax.Translation.InternalToAbstract

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Coverage
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.RecordPatterns
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Substitute.Pattern
import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.Rules.LHS.Implicit
import Agda.TheTypeChecker

import Agda.Interaction.Options
import Agda.Interaction.BasicOps

import Agda.Utils.Functor
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Null
import qualified Agda.Utils.Pretty as P
import Agda.Utils.Singleton
import Agda.Utils.Size
import qualified Agda.Utils.HashMap as HMap

#include "undefined.h"
import Agda.Utils.Impossible

type CaseContext = Maybe ExtLamInfo

-- | Parse variables (visible or hidden), returning their de Bruijn indices.
--   Used in 'makeCase'.

parseVariables
  :: QName           -- ^ The function name.
  -> InteractionId   -- ^ The hole of this function we are working on.
  -> Range           -- ^ The range of this hole.
  -> [String]        -- ^ The words the user entered in this hole (variable names).
  -> TCM [Int]       -- ^ The computed de Bruijn indices of the variables to split on.
parseVariables f ii rng ss = do

  -- Get into the context of the meta.
  mId <- lookupInteractionId ii
  updateMetaVarRange mId rng
  mi  <- getMetaInfo <$> lookupMeta mId
  enterClosure mi $ \ r -> do

    -- Get printed representation of variables in context.
    n  <- getContextSize
    xs <- forM (downFrom n) $ \ i -> do
      (,i) . P.render <$> prettyTCM (var i)

    reportSDoc "interaction.case" 20 $ do
      m   <- currentModule
      tel <- lookupSection m
      fv  <- getDefFreeVars f
      vcat
       [ text "parseVariables:"
       , text "current module  =" <+> prettyTCM m
       , text "current section =" <+> inTopContext (prettyTCM tel)
       , text $ "function's fvs  = " ++ show fv
       ]

    -- Get number of free variables.  These cannot be split on.
    fv <- getDefFreeVars f
    let numSplittableVars = n - fv

    -- Resolve each string to a variable.
    forM ss $ \ s -> do
      let failNotVar = typeError $ GenericError $ "Not a (splittable) variable: " ++ s
          done i
            | i < numSplittableVars = return i
            | otherwise             = failNotVar

      -- Note: the range in the concrete name is only approximate.
      resName <- resolveName $ C.QName $ C.Name r $ C.stringNameParts s
      case resName of

        -- Fail if s is a name, but not of a variable.
        DefinedName{}       -> failNotVar
        FieldName{}         -> failNotVar
        ConstructorName{}   -> failNotVar
        PatternSynResName{} -> failNotVar

        -- If s is a variable name in scope, get its de Bruijn index
        -- via the type checker.
        VarName x -> do
          (v, _) <- getVarInfo x
          case ignoreSharing v of
            Var i [] -> done i
            _        -> failNotVar

        -- If s is not a name, compare it to the printed variable representation.
        -- This fallback is to enable splitting on hidden variables.
        UnknownName -> do
          case filter ((s ==) . fst) xs of
            []      -> typeError $ GenericError $ "Unbound variable " ++ s
            [(_,i)] -> done i
            -- Issue 1325: Variable names in context can be ambiguous.
            _       -> typeError $ GenericError $ "Ambiguous variable " ++ s

-- | Lookup the clause for an interaction point in the signature.
--   Returns the CaseContext, the clause itself, and a list of previous clauses

-- Andreas, 2016-06-08, issue #289 and #2006.
-- This replace the old findClause hack (shutter with disgust).
getClauseForIP :: QName -> Int -> TCM (CaseContext, Clause, [Clause])
getClauseForIP f clauseNo = do
  (theDef <$> getConstInfo f) >>= \case
    Function{funClauses = cs, funExtLam = extlam} -> do
      let (cs1,cs2) = fromMaybe __IMPOSSIBLE__ $ splitExactlyAt clauseNo cs
          c         = fromMaybe __IMPOSSIBLE__ $ headMaybe cs2
      return (extlam, c, cs1)
    _ -> __IMPOSSIBLE__

-- | Entry point for case splitting tactic.
makeCase :: InteractionId -> Range -> String -> TCM (CaseContext , [A.Clause])
makeCase hole rng s = withInteractionId hole $ do
  InteractionPoint { ipMeta = mm, ipClause = ipCl} <- lookupInteractionPoint hole
  let meta = fromMaybe __IMPOSSIBLE__ mm
  (f, clauseNo) <- case ipCl of
    IPClause f clauseNo -> return (f, clauseNo)
    IPNoClause -> typeError $ GenericError $
      "Cannot split here, as we are not in a function definition"
  (casectxt, clause, prevClauses) <- getClauseForIP f clauseNo
  let perm = fromMaybe __IMPOSSIBLE__ $ clausePerm clause
      tel  = clauseTel  clause
      ps   = namedClausePats clause
  reportSDoc "interaction.case" 10 $ vcat
    [ text "splitting clause:"
    , nest 2 $ vcat
      [ text "f       =" <+> prettyTCM f
      , text "context =" <+> (prettyTCM =<< getContextTelescope)
      , text "tel     =" <+> prettyTCM tel
      , text "perm    =" <+> text (show perm)
      , text "ps      =" <+> text (show ps)
      ]
    ]
  let vars = words s
  if null vars then do
    -- split result
    (piTel, sc) <- fixTarget $ clauseToSplitClause clause
    -- Andreas, 2015-05-05 If we introduced new function arguments
    -- do not split on result.  This might be more what the user wants.
    -- To split on result, he can then C-c C-c again.
    -- Andreas, 2015-05-21 Issue 1516:  However, if only hidden
    -- arguments are introduced, C-c C-c virtually does nothing
    -- (as they are not shown and get lost on the way to emacs and back).
    newPats <- if null piTel then return False else do
      -- If there were any pattern introduce, they will only have effect
      -- if any of them is shown by the printer
      imp <- optShowImplicit <$> pragmaOptions
      return $ imp || any visible (telToList piTel)
    scs <- if newPats then return [sc] else do
      res <- splitResult f sc
      case res of
        Nothing  -> typeError $ GenericError $ "Cannot split on result here"
        Just cov -> ifNotM (optCopatterns <$> pragmaOptions) failNoCop $ {-else-} do
          -- Andreas, 2016-05-03: do not introduce function arguments after projection.
          -- This is sometimes annoying and can anyway be done by another C-c C-c.
          -- mapM (snd <.> fixTarget) $ splitClauses cov
          return $ splitClauses cov
    (casectxt,) <$> mapM (makeAbstractClause f) scs
  else do
    -- split on variables
    vars <- parseVariables f hole rng vars
    scs <- split f vars $ clauseToSplitClause clause
    -- filter out clauses that are already covered
    scs <- filterM (not <.> isCovered f prevClauses . fst) scs
    cs <- forM scs $ \(sc, isAbsurd) ->
            if isAbsurd then makeAbsurdClause f sc else makeAbstractClause f sc
    reportSDoc "interaction.case" 65 $ vcat
      [ text "split result:"
      , nest 2 $ vcat $ map (text . show) cs
      ]
    return (casectxt,cs)
  where

  failNoCop = typeError $ GenericError $
    "OPTION --copatterns needed to split on result here"

  -- Split clause on given variables, return the resulting clauses together
  -- with a bool indicating whether each clause is absurd
  split :: QName -> [Nat] -> SplitClause -> TCM [(SplitClause, Bool)]
  split f [] clause = return [(clause,False)]
  split f (var : vars) clause = do
    z <- splitClauseWithAbsurd clause var
    case z of
      Left err          -> typeError $ SplitError err
      Right (Left cl)   -> return [(cl,True)]
      Right (Right cov) -> concat <$> do
            forM (splitClauses cov) $ \ cl ->
              split f (mapMaybe (newVar cl) vars) cl

  -- Finds the new variable corresponding to an old one, if any.
  newVar :: SplitClause -> Nat -> Maybe Nat
  newVar c x = case ignoreSharing $ applyPatSubst (scSubst c) (var x) of
    Var y [] -> Just y
    _        -> Nothing


makeAbsurdClause :: QName -> SplitClause -> TCM A.Clause
makeAbsurdClause f (SClause tel ps _ t) = do
  reportSDoc "interaction.case" 10 $ vcat
    [ text "Interaction.MakeCase.makeCase: split clause:"
    , nest 2 $ vcat
      [ text "context =" <+> (prettyTCM =<< getContextTelescope)
      , text "tel =" <+> prettyTCM tel
      , text "ps =" <+> text (show ps)
      ]
    ]
  withCurrentModule (qnameModule f) $ do
    -- Andreas, 2015-05-29 Issue 635
    -- Contract implicit record patterns before printing.
    -- c <- translateRecordPatterns $ Clause noRange tel perm ps NoBody t False
    -- Jesper, 2015-09-19 Don't contract, since we do on-demand splitting
    let c = Clause noRange tel ps NoBody t False
    -- Normalise the dot patterns
    ps <- addContext tel $ normalise $ namedClausePats c
    reportSDoc "interaction.case" 60 $ text "normalized patterns: " <+> text (show ps)
    inTopContext $ reify $ QNamed f $ c { namedClausePats = ps }

-- | Make a clause with a question mark as rhs.
makeAbstractClause :: QName -> SplitClause -> TCM A.Clause
makeAbstractClause f cl = do
  A.Clause lhs _ _ _ _ <- makeAbsurdClause f cl
  reportSDoc "interaction.case" 60 $ text "reified lhs: " <+> text (show lhs)
  let ii = InteractionId (-1)  -- Dummy interaction point since we never type check this.
                               -- Can end up in verbose output though (#1842), hence not __IMPOSSIBLE__.
  let info = A.emptyMetaInfo   -- metaNumber = Nothing in order to print as ?, not ?n
  return $ A.Clause lhs [] (A.RHS $ A.QuestionMark info ii) [] False
