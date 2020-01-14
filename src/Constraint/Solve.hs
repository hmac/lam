-- The constraint solver
--
-- Based on the solver described in:
--   Modular Type Inference with Local Assumptions
--   (Vytiniotis, Peyton Jones, Schrijvers, Sulzmann)
--
-- Currently only works with simple equalities, but that's enough to handle
-- everything in Lam except for typeclasses.
--
-- To deal with typeclasses, we need to add the following:
-- Two more cases for interact: EQDICT, DDICT
-- the SIMPLIFY rule (except for SEQFEQ and SFEQFEQ)
-- the TOPREACT rule (except for FINST)

module Constraint.Solve where

import           Util

import           Data.Set                       (Set )

import           Control.Monad.State.Strict
import           Constraint

import           Prelude                 hiding ( interact )

-- This is the quadruple described in §7.3
-- It doesn't (yet) have all its elements, though
-- Missing:
-- - given constraints
-- - top level axiom scheme
type Quad = (Set Var, [Constraint])
type Solve = State Quad

data Error = OccursCheckFailure Type Type
           | ConstructorMismatch Type Type
           | UnsolvedConstraints Constraint
  deriving (Show, Eq)

-- See fig. 14
-- TODO: solveC should take as arguments:
-- - given constraints
-- - top level axiom scheme
solveC :: Set Var -> CConstraint -> Either Error ([Constraint], Subst)
solveC touchables c = case solve (touchables, flattenConstraint (simple c)) of
  Left err -> Left err
  Right (residual, subst) ->
    -- All implication constraints should be completely solvable
    let implications = implic (sub subst c)
    in  do
          results <- mapM (\(vars, q, cc) -> do (cs, s) <- solveC vars cc
                                                pure (mconcat cs, s))
                          implications
          case mconcat (map fst results) of
            CNil  -> Right (residual, subst <> concatMap snd results)
            impls -> Left (UnsolvedConstraints impls)

-- This is the actual top level solver function
-- Given a set of simple constraints it returns a substitution and any residual
-- constraints
solve :: Quad -> Either Error ([Constraint], Subst)
solve input = case rewriteAll input of
  Left err -> Left err
  -- See §7.5 for details
  Right (vars, cs) ->
    let (epsilon, residual) = partition
          (\case
            (TVar b :~: t) -> b `elem` vars && b `notElem` fuv t
            (t :~: TVar b) -> b `elem` vars && b `notElem` fuv t
            _         -> False
          )
          cs
        subst  = nubOn fst $ map (\case
                                  (TVar b :~: t) -> (b, t)
                                  (t :~: TVar b) -> (b, t)) epsilon
    in  Right (map (sub subst) residual, subst)

-- Solve a set of constraints
-- Repeatedly applies rewrite rules until there's nothing left to do
rewriteAll :: Quad -> Either Error Quad
rewriteAll quad@(_, cs) = case applyRewrite quad of
  Left err -> Left err
  Right quad'@(_, cs') ->
    if sort cs == sort cs' then Right quad' else rewriteAll quad'

-- Like solve but shows the solving history
solveDebug :: Quad -> Either Error [Quad]
solveDebug q = go [q] q
 where
  go hist quad@(_, d) = case applyRewrite quad of
    Left  err           -> Left err
    Right quad'@(_, d') -> if sort d == sort d'
      then Right (quad' : hist)
      else go (quad' : hist) quad'

run :: Solve (Either Error ()) -> Quad -> Either Error Quad
run f c = case runState f c of
  (Right (), c') -> Right c'
  (Left  e , _ ) -> Left e

-- Apply a round of rewriting
applyRewrite :: Quad -> Either Error Quad
applyRewrite quad = do
  c' <- run canonM quad
  run interactM c'

interactM :: Solve (Either Error ())
interactM = do
  (vars, constraints) <- get
  case firstJust (map interactEach (focusPairs constraints)) of
    Just constraints' -> do
      put (vars, constraints')
      pure $ Right ()
    Nothing -> pure $ Right ()
 where
  -- Try to interact the constraint with each one in the list.
  -- If a match is found, replace the two reactants with the result
  -- If no match is found, return the original list of constraints
  interactEach :: (Constraint, Constraint, [Constraint]) -> Maybe [Constraint]
  interactEach (a, b, cs) = case interact a b of
    Nothing -> Nothing
    Just c  -> Just (c : cs)

canonM :: Solve (Either Error ())
canonM = do
  (vars, constraints) <- get
  case canonAll (concatMap flattenConstraint constraints) of
    Left  err          -> pure $ Left err
    Right constraints' -> do
      put (vars, constraints')
      pure $ Right ()

canonAll :: [Constraint] -> Either Error [Constraint]
canonAll []       = Right []
canonAll (c : cs) = case canon c of
  Left  err -> Left err
  Right c'  -> (flatten c' ++) <$> canonAll cs

flatten :: Constraint -> [Constraint]
flatten (a :^: b) = a : flatten b
flatten c         = [c]

-- Canonicalise a constraint
canon :: Constraint -> Either Error Constraint
-- REFL: Reflexive equalities can be ignored
canon (a :~: b) | a == b = pure CNil

-- TDEC: Equalities between identical constructors can be decomposed to
-- equalities on their arguments
canon (TCon k as :~: TCon k' bs) | k == k' =
  pure $ foldl (:^:) CNil (zipWith (:~:) as bs)

-- FAILDEC: Equalities between constructor types must have the same constructor
canon (t@(TCon k _) :~: v@(TCon k' _)) | k /= k'            = Left (ConstructorMismatch t v)

-- OCCCHECK: a type variable cannot be equal to a type containing that variable
canon (v@(TVar _) :~: t) | v /= t && t `contains` v =
  Left $ OccursCheckFailure v t

-- ORIENT: Flip an equality around if desirable
canon (a :~: b) | canonCompare a b == GT            = pure (b :~: a)

-- Custom rule: CNil ^ c = c
canon (CNil :^: c   )                               = pure c
canon (c    :^: CNil)                               = pure c

-- Flattening rules only apply to type classes and type families, so are
-- omitted.
canon c                                             = pure c

-- Combine two canonical constraints into one
interact :: Constraint -> Constraint -> Maybe Constraint
-- EQSAME: Two equalities with the same LHS are combined to equate the RHS.
interact (TVar a :~: b) (TVar a' :~: c) | a == a' =
  Just $ (TVar a :~: b) :^: (b :~: c)

-- EQDIFF: One equality can be substituted into the other. We rely the ORIENT
-- rule in on prior canonicalisation to ensure this makes progress.
interact (TVar v1 :~: t1) (TVar v2 :~: t2) | v1 `elem` ftv t2 =
  Just $ (TVar v1 :~: t1) :^: (TVar v2 :~: sub [(v1, t1)] t2)

-- Redundant cases: drop CNil
interact CNil c    = Just c
interact c    CNil = Just c

-- If no rules match, signal failure
interact _    _    = Nothing

-- The simplify rules are omitted because I don't think they're relevant without
-- typeclasses and type families. May need to revisit this if I'm wrong.

-- The topreact rules are omitted because they're not relevant without
-- typeclasses.

contains :: Type -> Type -> Bool
contains a b | a == b  = True
contains (TCon _ ts) t = any (`contains` t) ts
contains _           _ = False

canonCompare :: Type -> Type -> Ordering
canonCompare (TVar (U _)) (TVar (R _)) = LT
canonCompare (TVar (R _)) (TVar (U _)) = GT
canonCompare (TVar a    ) (TVar b    ) = compare a b
canonCompare _            (TCon _ _  ) = LT
canonCompare (TCon _ _)   _            = GT

-- Calculate the free type variables of a type
ftv :: Type -> [Var]
ftv (TVar v   ) = [v]
ftv (TCon _ ts) = concatMap ftv ts

-- A list of each element in the given list paired with the remaining elements
focus :: [a] -> [(a, [a])]
focus = go []
 where
  go _  []       = []
  go ys (x : xs) = (x, reverse ys ++ xs) : go (x : ys) xs

focusPairs :: [a] -> [(a, a, [a])]
focusPairs xs =
  concatMap (\(y, ys) -> map (\(z, zs) -> (y, z, zs)) (focus ys)) (focus xs)

-- Extract the first Just value from a list
firstJust :: [Maybe a] -> Maybe a
firstJust []             = Nothing
firstJust (Just x  : _ ) = Just x
firstJust (Nothing : xs) = firstJust xs