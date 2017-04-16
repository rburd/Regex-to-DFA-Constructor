module NFA where

import Automata

import Control.Monad

import Data.Maybe

import Data.List as List

import Data.Set.Monad (Set)
import qualified Data.Set.Monad as Set

import Data.Map (Map)
import qualified Data.Map as Map 

import Test.HUnit (Test(..), (~:), (~?=), runTestTT, assertBool) 

-- The NFA transition function has epsilon transitions
-- and one state/symbol pair can map to multiple next states.
type Ntransition = Map (State, Maybe Char) (Set State)

data NFA = NFA { nstart :: State,
                 nstates :: States,
                 naccept :: States,
                 ntransition :: Ntransition,
                 nalphabet :: Set Char
               } deriving (Show)

-- TODO: write tests for this
instance Automata NFA where
  decideString nfa s = decideStringFromState nfa s (Set.singleton (nstart nfa)) where
    decideStringFromState :: NFA -> String -> Set State -> Maybe Bool
    decideStringFromState nfa (c:cs) qs 
      | Set.member c (nalphabet nfa) = 
          -- add all states reachable from the current set of states by reading the next symbol
          let qs' = do
                    q <- qs
                    case Map.lookup (q, Just c) (ntransition nfa) of 
                      Just nqs -> nqs
                      Nothing  -> Set.empty
          -- additionally add the states reachable by epsilon transitions from this new set of states
          in let eqs' = do
                        q <- qs'
                        case Map.lookup (q, Nothing) (ntransition nfa) of
                          Just nqs -> nqs
                          Nothing  -> Set.empty
          in decideStringFromState nfa cs (Set.union qs' eqs')
      | otherwise                    = Nothing
    decideStringFromState nfa [] qs  = Just $ any accepts (Set.toList qs) where
                                       accepts q = Set.member q $ naccept nfa


-- We implement NFA equality as exact equality
instance Eq NFA where
  (==) n1 n2 = 
    nalphabet n1 == nalphabet n2
    && nstates n1 == nstates n2
    && naccept n1 == naccept n2
    && ntransition n1 == ntransition n2
    && nstart n1 == nstart n2

singleCharNfa :: Char -> NFA --TODO: Change type signature to DFA when DFA converter is implemented 
singleCharNfa char = 
  let ab = Set.singleton char
      singleStates = Set.fromList [0,1]
      singleTransition = Map.fromList [((0, Just char), Set.singleton 1)]
      singleAccept = Set.singleton 1
  in NFA {nstart = 0, 
          nstates = singleStates, 
          naccept = singleAccept,
          ntransition = singleTransition, 
          nalphabet = ab}

testSingleCharNfa :: Test
testSingleCharNfa = TestList [
  singleCharNfa 'a' ~?= NFA {
    nstart = 0,
    nstates = Set.fromList [0,1],
    naccept = Set.singleton 1,
    ntransition = Map.fromList [((0,Just 'a'), Set.singleton 1)],
    nalphabet = Set.singleton 'a'
  }]

unionNfa :: NFA -> NFA -> NFA
unionNfa n1 n2 = 
  let ab = Set.union (nalphabet n1) (nalphabet n2)
      lastStateN1 = Set.size (nstates n1)
      firstStateN2 = lastStateN1 + 1
      lastStateN2 = lastStateN1 + Set.size (nstates n2)
      lastStateUnion = lastStateN2 + 1
      s0 = Set.union 
             (fmap (+1) (nstates n1)) 
             (fmap (+ firstStateN2) (nstates n2))
      s1 = Set.insert lastStateUnion s0
      states = Set.insert 0 s1
      incN1T = fmap (fmap (+1)) $ 
                 Map.mapKeys (\(a,b) -> (a + 1,b)) (ntransition n1)
      incN2T = fmap (fmap (+ firstStateN2)) $
                 Map.mapKeys (\(a,b) -> (a + firstStateN2,b)) (ntransition n2)
      u0 = Map.union incN1T incN2T
      u1 = Map.insert (0, Nothing) (Set.fromList [1, firstStateN2]) u0
      u2 = Map.insert (lastStateN1, Nothing) (Set.singleton lastStateUnion) u1
      transitions = Map.insert 
                      (lastStateN2, Nothing) 
                      (Set.singleton lastStateUnion) 
                      u2
      accepts = Set.singleton lastStateUnion
  in NFA {nstart = 0, 
          nstates = states,
          naccept = accepts,
          ntransition = transitions, 
          nalphabet = ab}

testUnionNfa :: Test
testUnionNfa = TestList [
  unionNfa (singleCharNfa 'a') (singleCharNfa 'b') ~?= 
    NFA {
      nstart = 0,
      nstates = Set.fromList [0,1,2,3,4,5],
      naccept = Set.singleton 5,
      ntransition = Map.fromList [((0,Nothing), Set.fromList [1,3]),
                                  ((1, Just 'a'), (Set.singleton 2)),
                                  ((3, Just 'b'), (Set.singleton 4)),
                                  ((2,Nothing), (Set.singleton 5)),
                                  ((4,Nothing), (Set.singleton 5))],
      nalphabet = Set.fromList "ab"
    }]

concatNfa :: NFA -> NFA -> NFA
concatNfa n1 n2 =
  let ab = Set.union (nalphabet n1) (nalphabet n2)
      firstStateN1 = 1
      lastStateN1 = Set.size (nstates n1)
      firstStateN2 = lastStateN1 + 1
      lastStateN2 = lastStateN1 + Set.size (nstates n2)
      states = Set.insert 0 $ Set.union 
                 (fmap (+1) (nstates n1)) 
                 (fmap (+ firstStateN2) (nstates n2))
      incN1T = fmap (fmap (+1)) $ 
                 Map.mapKeys (\(a,b) -> (a + 1,b)) (ntransition n1)
      incN2T = fmap (fmap (+ firstStateN2)) $
                 Map.mapKeys (\(a,b) -> (a + firstStateN2,b)) (ntransition n2)
      t0 = Map.union incN1T incN2T
      t1 = Map.insert (0, Nothing) (Set.fromList [firstStateN1, firstStateN2]) t0
      transitions = Map.insert (lastStateN1, Nothing) (Set.singleton firstStateN2) t1
      accepts = Set.singleton lastStateN2
  in NFA {nstart = 0, 
          nstates = states,
          naccept = accepts,
          ntransition = transitions, 
          nalphabet = ab}

testConcatNfa :: Test
testConcatNfa = TestList [
  concatNfa (singleCharNfa 'a') (singleCharNfa 'b') ~?= 
    NFA {
      nstart = 0,
      nstates = Set.fromList [0,1,2,3,4],
      naccept = Set.singleton 4,
      ntransition = Map.fromList [((0,Nothing), Set.fromList [1,3]),
                                  ((1, Just 'a'), (Set.singleton 2)),
                                  ((3, Just 'b'), (Set.singleton 4)),
                                  ((2,Nothing), (Set.singleton 3))],
      nalphabet = Set.fromList "ab"
    }]

kleeneNfa :: NFA -> NFA
kleeneNfa n = 
  let firstStateN = 0
      lastStateN = Set.size (nstates n)
      states = Set.insert lastStateN $ Set.insert firstStateN $ fmap (+1) (nstates n)
      incNT = fmap (fmap (+1)) $ 
                 Map.mapKeys (\(a,b) -> (a + 1,b)) (ntransition n)
      t0 = Map.insert (firstStateN,Nothing) (Set.fromList [1, lastStateN]) incNT
      transitions = Map.insert (lastStateN - 1,Nothing) (Set.fromList [lastStateN,1]) t0
      accepts = Set.singleton lastStateN
    in NFA {nstart = 0,
            nstates = states,
            naccept = accepts,
            ntransition = transitions,
            nalphabet = nalphabet n}

testKleeneNfa :: Test
testKleeneNfa = TestList [
  kleeneNfa (concatNfa (singleCharNfa 'a') (singleCharNfa 'b')) ~?= 
    NFA {
      nstart = 0,
      nstates = Set.fromList [0,1,2,3,4,5],
      naccept = Set.singleton 5,
      ntransition = Map.fromList [((0,Nothing), Set.fromList [1,5]),
                                  ((1,Nothing), Set.fromList [2,4]),
                                  ((2, Just 'a'), (Set.singleton 3)),
                                  ((4, Just 'b'), (Set.singleton 5)),
                                  ((4, Nothing), (Set.fromList [5,1])),
                                  ((3,Nothing), (Set.singleton 4))],
      nalphabet = Set.fromList "ab"
    }] 

main :: IO ()
main = do
    runTestTT $ TestList [testSingleCharNfa,
                          testUnionNfa,
                          testConcatNfa,
                          testKleeneNfa]
    return ()