{-# LANGUAGE RecordWildCards #-}

module SoPSat.Satisfier
  ( -- * State
    SolverState
    -- * State manipulation
  , declare
  , assert
    -- * State execution
  , runStatements
  , evalStatements
  )
where

import Control.Applicative ((<|>))
import Control.Arrow       (second)
import Control.Monad       (when)

import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (isNothing)

import SoPSat.SoP
import SoPSat.Unify
import SoPSat.Range
import SoPSat.NewtonsMethod
import SoPSat.SolverMonad


parts :: [a] -> [[a]]
parts [] = []
parts (x:xs) = xs : map (x:) (parts xs)


-- ^ Declares symbol in the state with the default interval
-- If symbol exists preserves the old interval
declareSymbol :: (Ord c) => Symbol c -> SolverState c ()
declareSymbol (I _) = return ()
declareSymbol (C c) = do
  ranges <- getRanges
  when (isNothing (M.lookup c ranges)) (putRange c range)
  where
    range = Range (Bound (toSoP (I 0))) Inf
declareSymbol (E b p) = declareSoP b >> declareProduct p

-- ^ Similar to @declareSoP@ but for @Product@
declareProduct :: (Ord c) => Product c -> SolverState c ()
declareProduct = mapM_ declareSymbol . unP

-- ^ Declare SoP in the state with default values
-- Creates range for free-variables
declareSoP :: (Ord c) => SoP c -> SolverState c ()
declareSoP = mapM_ declareProduct . unS


-- ^ Declare equality of two expressions
declareEq :: (Ord c)
          => SoP c
          -- | First expression
          -> SoP c
          -- | Second expression
          -> SolverState c Bool
          -- | Similar to @declare@ but handles only equalities
          -- Adds new unifiers to the state
declareEq u v =
  do
    us <- getUnifiers
    let
      u' = substsSoP us u
      v' = substsSoP us v
    (Range low1 up1) <- getRangeSoP u'
    (Range low2 up2) <- getRangeSoP v'
    lowRes <- boundComp low1 low2
    upRes <- boundComp up1 up2

    -- Declaration and assertions of expression is done on the whole domain
    -- if two expressions are equal, they will have intersecting domain
    --
    -- g(x) in [1,5] and forall x  g(x) = f(x) then f(x) in [1,5
    lowerUpdate <-
      case (lowRes,low1,low2) of
        (True,_,Bound lowB2) -> propagateInEqSoP u' GeR lowB2
        (False,Bound lowB1,_) -> propagateInEqSoP v' GeR lowB1
        (_,_,_) -> return True

    upperUpdate <-
      case (upRes,up1,up2) of
        (True,_,Bound upB2) -> propagateInEqSoP u' LeR upB2
        (False,Bound upB1,_) -> propagateInEqSoP v' LeR upB1
        (_,_,_) -> return True
    
    declareEq' u' v'
    return (lowerUpdate && upperUpdate)
  where
    boundComp Inf _ = return False
    boundComp _ Inf = return True
    boundComp (Bound a) (Bound b) = assert (SoPE a b LeR)

declareEq' :: (Ord c) => SoP c -> SoP c -> SolverState c ()
declareEq' (S [P [C x]]) v = putUnifiers [Subst x v]
declareEq' u (S [P [C x]]) = putUnifiers [Subst x u]
declareEq' u v = putUnifiers $ unifiers u v


-- ^ Updates interval information for a symbol
propagateInEqSymbol :: (Ord c)
                    => Symbol c
                    -- | Updated symbol
                    -> OrdRel
                    -- | Relationship between the symbol and target
                    -> SoP c
                    -- | Target Boundary
                    -> SolverState c Bool
                    -- | Similat to @declareInEq@
propagateInEqSymbol (I _) _ _ =
  return True -- No need to update numbers
propagateInEqSymbol (C c) rel bound = do
  (Range low up) <- getRange c
  case rel of
    LeR -- TODO: Check for update being valid (newUpBound >= lowBound)
      | up == Inf -- Range isn't bounded from the top can unconditionally update
        -> putRange c (Range low rangeBound)
      | otherwise -- TODO: Check for the range not being widened
        -> putRange c (Range low rangeBound)
    GeR -- TODO: Check for update being valid (newLowBound <= upBound)
      | low == Bound (toSoP (I 0)) -- Range isn't bounded from the bottom can unconditionally update
        -> putRange c (Range rangeBound up)
      | otherwise -- TODO: Check for the range not being widened
        -> putRange c (Range rangeBound up)
    EqR -> error "propagateInEqSymbol:EqR: unreachable"
  return True
  where
    rangeBound = Bound bound
propagateInEqSymbol (E b (P [I i])) rel (S [P [I j]])
  | (Just p) <- integerRt i j
  = propagateInEqSoP b rel (toSoP (I p))
propagateInEqSymbol (E (S [P [I i]]) p) rel (S [P [I j]])
  | (Just e) <- integerLogBase i j
  = propagateInEqProduct p rel (toSoP (I e))
propagateInEqSymbol _ _ _ = fail ""

-- ^ Propagates interval information down the Product
propagateInEqProduct :: (Ord c)
                     => Product c
                     -- | Updates expression
                     -> OrdRel
                     -- | Relationship between the expression and target
                     -> SoP c
                     -- | Target boundary
                     -> SolverState c Bool
                     -- | Similar to @declareInEq@
propagateInEqProduct (P [symb]) rel target_bound = propagateInEqSymbol symb rel target_bound
propagateInEqProduct (P ss) rel target_bound =
  and <$> mapM (uncurry propagate) (zipWith (curry (second P)) ss (parts ss))
  where
    -- a <= x * y => a/y <= x and a/x <= y
    -- Currently simply propagating the bound further
    -- a <= x * y => a <= x and a <= y
    propagate symb _prod = propagateInEqSymbol
                          symb rel
                          target_bound
                          -- (mergeSoPDiv target_bound prod)
    -- TODO: implement SoP division
    -- mergeSoPDiv = 

-- ^ Propagates interval information down the SoP
propagateInEqSoP :: (Ord c)
                 => SoP c
                 -- | Updated expression
                 -> OrdRel
                 -- | Relationship between the expression and target
                 -> SoP c
                 -- | Target boundary
                 -> SolverState c Bool
                 -- | Similar to @declareInEq@
propagateInEqSoP (S [P [symb]]) rel target_bound = propagateInEqSymbol symb rel target_bound
propagateInEqSoP (S ps) rel target_bound =
  and <$> mapM (uncurry propagate) (zipWith (curry (second S)) ps (parts ps))
  where
    -- a <= x + y => a - y <= x and a - x <= y
    propagate prod sm = propagateInEqProduct
                        prod rel
                        (mergeSoPSub target_bound sm)

-- ^ Declare inequality of two expressions
declareInEq :: (Ord c)
            => OrdRel
            -- | Relationship between expressions
            -> SoP c
            -- | Left-hand side expression
            -> SoP c
            -- | Right-hand side expression
            -> SolverState c Bool
            -- | Similat to @declare@ but handles only inequalities
            -- Updates interval information in the state
declareInEq EqR u v = declareEq u v >> return True
declareInEq op u v =
  do
    us <- getUnifiers
    let
      u' = substsSoP us u
      v' = substsSoP us v
      (u'', v'') = splitSoP u' v'
    -- If inequality holds with current interval information
    -- then no need to update it
    res <- assert (SoPE u'' v'' op)
    if res then return True
      else
      case op of
        LeR -> do
          a1 <- propagateInEqSoP u'' LeR v''
          a2 <- propagateInEqSoP v'' GeR u''
          return (a1 && a2)
        GeR -> do
          a1 <- propagateInEqSoP u'' GeR v''
          a2 <- propagateInEqSoP v'' LeR u''
          return (a1 && a2)

-- ^ Declare expression to the state
declare :: Ord c
        => SoPE c
        -- | Expression to declare
        -> SolverState c Bool
        -- | True -- if expression was declared
        -- False -- if expression contradicts current state
        --
        -- State will become @Nothing@ if it cannot reason about these kind of expressions
declare SoPE{..} = do
  declareSoP lhs
  declareSoP rhs
  case op of
    EqR -> declareEq lhs rhs >> return True
    _   -> declareInEq op lhs rhs

-- ^ Assert that two expressions are equal using unifiers from the state
assertEq :: Ord c
         => SoP c
         -- | Left-hand side expression
         -> SoP c
         -- | Right-hand size expression
         -> SolverState c Bool
         -- | Similar to assert but only checks for equality @lhs = rhs@
assertEq lhs rhs = do
  us <- getUnifiers
  let
    lhs' = substsSoP us lhs
    rhs' = substsSoP us rhs
  return ((lhs == rhs) || (lhs' == rhs'))

-- ^ Assert using only ranges stores in the state
assertRange :: Ord c
            => SoP c
            -- | Left-hand side expression
            -> SoP c
            -- | Right-hand size expression
            -> SolverState c Bool
            -- | Similar to @assert@ but uses only intervals from the state to check @lhs <= rhs@
assertRange lhs rhs = do
  us <- getUnifiers
  let
    (lhs',rhs') = splitSoP lhs rhs
    lhs'' = substsSoP us lhs'
    rhs'' = substsSoP us rhs'
  r1 <- assertRange' lhs' rhs'
  r2 <- assertRange' lhs'' rhs''
  return (r1 || r2)

assertRange' :: Ord c => SoP c -> SoP c -> SolverState c Bool
assertRange' lhs rhs = do
  (Range _ up1) <- getRangeSoP lhs
  (Range low2 up2) <- getRangeSoP rhs
  -- If both sides increase infinitely, fail to use Newton's method
  -- Information about rate of growth is required
  -- to check inequality on the whole domain
  if up1 == up2 && up2 == Inf then fail ""
    else case (up1,low2) of
           (Inf,_) -> return False
           (_,Inf) -> return False
           (Bound (S [P [I i1]]), Bound (S [P [I i2]]))
             -> return (i1 <= i2)
           (Bound ub1,            Bound lb2)
           -- Orders of recursive checks matters
           -- @runLemma2@ in the tests loops indefinitely
             -> assert (SoPE lhs lb2 LeR)
                <|> assert (SoPE ub1 rhs LeR)
                <|> assert (SoPE ub1 lb2 LeR)

-- ^ Assert using only Newton's method
assertNewton :: Ord c
             => SoP c
             -- | Left-hand side expression
             -> SoP c
             -- | Right-hand side expression
             -> SolverState c Bool
             -- | Similar to @assert@ but uses only Newton's method to check @lhs <= rhs@
assertNewton lhs rhs =
  do
    us <- getUnifiers
    let
      lhs'  = substsSoP us lhs
      rhs'  = substsSoP us rhs
      one   = toSoP (I 1)
      -- Add one to expressions to find negative values and not zeros
      expr1 = mergeSoPAdd (mergeSoPSub rhs lhs) one
      expr2 = mergeSoPAdd (mergeSoPSub rhs' lhs') one

    res1 <- checkExpr expr1
    res2 <- checkExpr expr2

    return (res1 || res2)
  where
    checkExpr :: (Ord c) => SoP c -> SolverState c Bool
    checkExpr expr
      | (Right binds) <- newtonMethod expr
      = not <$> checkBinds binds
      | otherwise
      = return True

    checkBinds :: (Ord c, Ord n, Floating n) => Map c n -> SolverState c Bool
    checkBinds binds = and <$> mapM (uncurry (checkBind binds)) (M.toList binds)

    checkBind :: (Ord c, Ord n, Floating n) => Map c n -> c -> n -> SolverState c Bool
    checkBind binds c v = do
      (Range left right) <- getRange c
      return (checkLeft binds v left && checkRight binds v right)

    checkLeft :: (Ord c, Ord n, Floating n) => Map c n -> n -> Bound c -> Bool
    checkLeft _ _ Inf = True
    checkLeft binds v (Bound sop) = evalSoP sop binds <= v

    checkRight :: (Ord c, Ord n, Floating n) => Map c n -> n -> Bound c -> Bool
    checkRight _ _ Inf = True
    checkRight binds v (Bound sop) = v <= evalSoP sop binds

-- ^ Assert if given expression holds in the current environment
assert :: Ord c
       => SoPE c
       -- | Asserted expression
       -> SolverState c Bool
       -- | True -- if expressions holds
       -- False -- otherwise
       --
       -- State will become @Nothing@ if it cannot reason about these kind of expressions
assert SoPE{..} = do
  declareSoP lhs
  declareSoP rhs
  case op of
    EqR -> assertEq lhs rhs
    LeR -> do
      r1 <- assertEq lhs rhs
      if r1 then return True
        else do
        assertRange lhs rhs <|> assertNewton lhs rhs
    GeR -> do
      r1 <- assertEq lhs rhs
      if r1 then return True
        else do
        assertRange rhs lhs <|> assertNewton rhs lhs
