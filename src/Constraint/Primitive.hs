module Constraint.Primitive
  ( env
  )
where

import           Constraint.Generate.M
import           Constraint
import           Canonical                      ( Name(..) )
import           Constraint.Expr

import qualified Data.Map.Strict               as Map

env :: Env
env = Map.fromList
  -- (::) : a -> [a] -> [a]
  [ ( TopLevel modPrim "::"
    , Forall
      [R "a"]
      mempty
      (TVar (R "a") `fn` TCon (TopLevel modPrim "List") [TVar (R "a")] `fn` TCon
        (TopLevel modPrim "List")
        [TVar (R "a")]
      )
    )
  ]