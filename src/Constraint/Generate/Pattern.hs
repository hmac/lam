module Constraint.Generate.Pattern
  ( generatePattern
  )
where

-- Constraint generation for nested patterns
-- If we can do this, we can generate constraints for pattern matching function
-- definitions and other fun stuff.

import           Constraint
import           Constraint.Expr
import           Constraint.Generate.M
import           Syntax                         ( Pattern_(..) )

import qualified Data.Map.Strict               as Map

-- Given an environment, the type of the scrutinee, and a pattern, generate a
-- type for the pattern, a set of constraints, and a new environment in which to
-- typecheck the pattern branch.
--
-- Example:
--   case (s : Pair Bool Nat) of
--     (MkPair x Zero) -> w
-- generates: (MkPair x Zero) : Pair Bool Nat
--            {some constraints which solve to produce (x : Bool)}
--            an environment in which to typecheck w, containing (x : Bool)
--
-- Note: this code isn't taken from the Modular Type Inference paper - it's
-- written by me instead. Treat it with caution and assume it has bugs.
generatePattern :: Env -> Type -> Pattern -> GenerateM (Type, CConstraint, Env)
generatePattern env st (IntPat _) = do
  let c = Simple (st :~: TInt)
  pure (TInt, c, env)
generatePattern env st (VarPat x) = do
  u <- TVar <$> fresh
  let env' = Map.insert x (Forall [] mempty u) env
  let c    = Simple (u :~: st)
  pure (u, c, env')
generatePattern env st WildPat = do
  -- The wildcard can't be used, so we don't need to extend the environment.
  u <- TVar <$> fresh
  let c = Simple (u :~: st)
  pure (u, c, env)
generatePattern env st (StringPat _) = do
  let c = Simple (st :~: TString)
  pure (TString, c, env)
generatePattern env st (TuplePat pats) = do
    -- generate each subpattern
  (patTypes, patConstraints, patEnvs) <- do
    freshPatTypes <- mapM (\p -> fresh >>= \v -> pure (TVar v, p)) pats
    (tys, constraints, envs) <-
      unzip3 <$> mapM (uncurry (generatePattern env)) freshPatTypes
    pure (tys, mconcat constraints, mconcat envs)
  -- generate a fresh variable for the type of the whole tuple pattern
  beta <- TVar <$> fresh
  let betaConstraints =
        Simple $ mconcat [beta :~: st, beta :~: mkTupleType patTypes]
  pure (beta, patConstraints <> betaConstraints, patEnvs <> env)
generatePattern env st (ListPat []) = do
  -- generate a fresh variable for the (unknown) type of the list elements
  elemType <- TVar <$> fresh
  -- generate a fresh variable for the type of the whole list pattern
  beta     <- TVar <$> fresh
  let betaConstraints = Simple $ mconcat [beta :~: st, beta :~: list elemType]
  pure (beta, betaConstraints, env)
generatePattern env st (ListPat pats) = do
    -- generate each subpattern
  (patTypes, patConstraints, patEnvs) <- do
    freshPatTypes <- mapM (\p -> fresh >>= \v -> pure (TVar v, p)) pats
    (tys, constraints, envs) <-
      unzip3 <$> mapM (uncurry (generatePattern env)) freshPatTypes
    pure (tys, mconcat constraints, mconcat envs)
  -- the type of each pattern must be the same
  -- N.B. it's guaranteed that patTypes has at least one element
  let (listConstraints, _) = foldl (\(c, t') t -> (c <> t' :~: t, t))
                                   (mempty, head patTypes)
                                   (tail patTypes)
  -- generate a fresh variable for the type of the whole list pattern
  beta <- TVar <$> fresh
  let betaConstraints =
        Simple $ mconcat [beta :~: st, beta :~: list (head patTypes)]
  pure
    ( beta
    , patConstraints <> betaConstraints <> Simple listConstraints
    , patEnvs <> env
    )
generatePattern env st (ConsPat k pats) = case Map.lookup k env of
  Nothing -> do
    u <- TVar <$> fresh
    pure (u, mempty, env)
  Just (Forall as cs kt) -> do -- TODO: should we be using cs?
    -- generate new uvars for each a in as
    ys <- mapM (const fresh) as
    -- construct tyvar substitution
    let subst = zip as (map TVar ys)
    let (TCon tyname tyargs, tyconargs) =
          let ts = unfoldFnType kt
          in  (sub subst (last ts), map (sub subst) (init ts))
    let scrutConstraint = Simple (TCon tyname (map TVar ys) :~: st)
    -- generate each subpattern and apply the substitution to each
    (patTypes, patConstraints, patEnvs) <- do
      freshPatTypes <- mapM (\p -> fresh >>= \v -> pure (TVar v, p)) pats
      (tys, constraints, envs) <-
        unzip3 <$> mapM (uncurry (generatePattern env)) freshPatTypes
      pure (map (sub subst) tys, mconcat constraints, mconcat envs)
    -- Each pattern type should be equal to the corresponding type from the type
    -- constructor
    let patEqualityConstraints = mconcat $ zipWith
          (\patTy argTy -> Simple (patTy :~: argTy))
          patTypes
          tyconargs
    -- generate a fresh variable for the type of the whole pattern
    beta <- TVar <$> fresh
    let betaConstraint = Simple $ beta :~: st <> beta :~: TCon tyname tyargs
    pure
      ( beta
      , patEqualityConstraints
      <> scrutConstraint
      <> patConstraints
      <> betaConstraint
      , patEnvs <> env
      )