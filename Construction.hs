
module Construction where

import Regex
import Alpha
import Automata
import DFA
import NFA

import Data.Function
import Data.List
import qualified Data.List as List

import Data.List.NonEmpty as NonEmpty

import Control.Monad.State

import Data.Map (Map)
import qualified Data.Map as Map 

import Data.Set.Monad (Set)
import qualified Data.Set.Monad as Set

import Text.Parsec as P hiding (Empty, State)

import Debug.Trace

import Test.HUnit (Test(..), (~:), (~?=), runTestTT, assertBool)  

-- construct a DFA from a regular expression via the thompson construction algorithm
thompsonConstruction :: RegExp -> DFA
thompsonConstruction regexp = let nfa = thompsonNfaConstruction regexp
                              in dfaMinimization $ dfaConstruction nfa

-- constructs an NFA from a regular expression
thompsonNfaConstruction :: RegExp -> NFA
thompsonNfaConstruction r = construction r (alpha r) where
  construction Empty ab = emptyStringNfa ab
  construction Void  ab = emptySetNfa ab
  construction (Char cs) ab = foldr1 (\n1 n2 -> unionNfa n1 n2) (singleCharNfa <$> cs)
  construction (Alt Empty r2) ab = acceptsEmptyNfa (construction r2 ab)
  construction (Alt r1 Empty) ab = acceptsEmptyNfa (construction r1 ab)
  construction (Alt r1 r2) ab = unionNfa (construction r1 ab) (construction r2 ab) 
  construction (Seq r1 r2) ab = concatNfa (construction r1 ab) (construction r2 ab) 
  construction (Star r) ab = kleeneNfa (construction r ab)

testThompsonNfaConstruction :: Test
testThompsonNfaConstruction = "thompson construction of NFA from regex" ~: 
  TestList [
    thompsonNfaConstruction (rChar "a") ~?= 
      NFA {
      nstart = 0,
      nstates = Set.fromList [0,1],
      naccept = Set.singleton 1,
      ntransition = Map.fromList [((0,Just 'a'), Set.singleton 1)],
      nalphabet = return 'a'
    },
    thompsonNfaConstruction (rStar (rSeq (rChar "a") (rChar "b"))) ~?= 
      NFA {
        nstart = 0,
        nstates = Set.fromList [0,1,2,3,4,5],
        naccept = Set.singleton 5,
        ntransition = Map.fromList [((0, Nothing), Set.fromList [1,5]),
                                    ((1, Just 'a'), Set.singleton 2),
                                    ((2, Nothing), (Set.singleton 3)),
                                    ((3, Just 'b'), (Set.singleton 4)),
                                    ((4, Nothing), (Set.fromList [1,5]))],
        nalphabet = NonEmpty.fromList "ab"
      },
      thompsonNfaConstruction (rAlt (rChar "a") (rChar "b")) ~?=
        NFA {
          nstart = 0,
          nstates = Set.fromList [0,1,2,3,4,5],
          naccept = Set.singleton 5,
          ntransition = Map.fromList [((0,Nothing), Set.fromList [1,3]),
                                      ((1, Just 'a'), (Set.singleton 2)),
                                      ((3, Just 'b'), (Set.singleton 4)),
                                      ((2,Nothing), (Set.singleton 5)),
                                      ((4,Nothing), (Set.singleton 5))],
          nalphabet = NonEmpty.fromList "ab"
        },
      thompsonNfaConstruction (rAlt (rStar (rSeq (rChar "a") (rChar "b"))) 
                    (rStar (rChar "b"))) ~?= 
        NFA {
          nstart = 0, 
          nstates = Set.fromList [0,1,2,3,4,5,6,7,8,9,10,11],
          naccept = Set.fromList [11],
          ntransition = Map.fromList [((0,Nothing),Set.fromList [1,5]),
                                      ((1,Nothing),Set.fromList [2,4]),
                                      ((2,Just 'b'),Set.fromList [3]),
                                      ((3,Nothing),Set.fromList [2,4]),
                                      ((4,Nothing),Set.fromList [11]),
                                      ((5,Nothing),Set.fromList [6,10]),
                                      ((6,Just 'a'),Set.fromList [7]),
                                      ((7,Nothing),Set.fromList [8]),
                                      ((8,Just 'b'),Set.fromList [9]),
                                      ((9,Nothing),Set.fromList [6,10]),
                                      ((10,Nothing),Set.fromList [11])], 
          nalphabet = NonEmpty.fromList "ba"}]

-- data type tracking state of DFA in DFA-building process 
data DFASt a = DFASt { qStateCounter :: Int, 
                       qCorr  :: Map a QState,
                       getDfa :: DFA } deriving (Eq, Show)

initDfaSt :: Alpha -> DFASt a
initDfaSt ab = 
  let initDfa = DFA {
    dstart = 0, 
    dstates = Set.empty, 
    daccept = Set.empty,
    dtransition = Map.empty, 
    dalphabet = ab }
  in DFASt {
    qStateCounter = 0,
    qCorr = Map.empty,
    getDfa = initDfa}

-- Update the state with a new qstate if it is not there already
lookupUpdate :: Ord a => a -> State (DFASt a) (QState, Bool)
lookupUpdate x = do
   dst <- get
   let m = qCorr dst
   let dq = qStateCounter dst
   let dfa = getDfa dst
   case Map.lookup x m of
     Nothing  -> put DFASt { qStateCounter = dq + 1,
                             qCorr = Map.insert x dq m,
                             getDfa = withQState dq dfa}
                 >> return (dq, True)
     Just dq' -> return (dq', False)

getAcceptStates :: Ord a => (a -> Bool) -> Map a QState -> Set QState
getAcceptStates pred qCorr = 
  let statesList = do
      x <- Map.keys qCorr
      if pred x
      then case (Map.lookup x qCorr) of
        Just dq -> return dq
        Nothing -> []
      else []
    in Set.fromList statesList

-- Create a transition from the state associated with x
-- to the state found by applying the function next to x.
-- Puts next in the map if it does not yet exist.
addTransition :: Ord a => (a -> Char -> a) -> (a, Char) -> State (DFASt (a)) (Maybe a)
addTransition next (x, c) = do
  let x' = next x c
  (dq, _) <- lookupUpdate x
  (dq', isNew) <- lookupUpdate x'
  dst <- get
  put dst { getDfa = withTransition (dq,c) dq' (getDfa dst)}
  if isNew
    then return $ Just x'
    else return Nothing

-- Constructs DFA by determining the set of states reachable 
-- from the current set of states in the NFA.
-- Each set of states in the NFA is mapped to a single state in the DFA.
dfaStateConstruction :: NFA -> Maybe (Set QState) -> State (DFASt (Set QState)) ()
dfaStateConstruction nfa Nothing = return ()
dfaStateConstruction nfa (Just nq) = do
      dst <- get
      let alpha = nalphabet nfa
      let qCharPairs = (\c -> (nq,c)) <$> alpha
      let next nq c = epsilonReachable nfa (symbolReachable nfa nq c)
      nq's <- sequence $ addTransition next <$> qCharPairs
      sequence_ $ dfaStateConstruction nfa <$> nq's
      return ()

-- Constructs a DFA from an NFA by the power set construction
dfaConstruction :: NFA -> DFA 
dfaConstruction nfa = 
  let initStateSet = Just $ epsilonReachable nfa $ Set.singleton (nstart nfa)
      dst = execState (dfaStateConstruction nfa initStateSet) (initDfaSt $ nalphabet nfa)
      accepts = getAcceptStates (\nq -> acceptsSomeState nfa nq) (qCorr dst)
  in withAccepts accepts (getDfa dst)

testDfaConstruction :: Test 
testDfaConstruction = "DFA correctly constructed from NFA" ~:
  TestList [
    dfaConstruction (singleCharNfa 'a') ~?= 
      DFA {dstart = 0, 
           dstates = Set.fromList [0,1,2],
           daccept = Set.fromList [1],
           dtransition = Map.fromList [((0,'a'),1),((1,'a'),2),((2,'a'),2)],
           dalphabet = return 'a'},
    dfaConstruction (unionNfa (singleCharNfa 'a') (singleCharNfa 'b')) ~?= 
      DFA {dstart = 0,
           dstates = Set.fromList [0,1,2,3],
           daccept = Set.fromList [1,3],
           dtransition = Map.fromList [((0,'a'),1),
                                       ((0,'b'),3),
                                       ((1,'a'),2),
                                       ((1,'b'),2),
                                       ((2,'a'),2),
                                       ((2,'b'),2),
                                       ((3,'a'),2),
                                       ((3,'b'),2)],
           dalphabet = NonEmpty.fromList "ab"}]

-- Takes a DFA and minimizes it by deleting all unreachable states
-- and identifying/merging all indistinguishable states 
dfaMinimization :: DFA -> DFA
dfaMinimization d = 
  let reachableDfa = deleteUnreachable d (Set.toList (dstates d)) in
  case mergeIndistinguishable reachableDfa of
    Just dfa -> dfa
    Nothing -> reachableDfa

testDfaMinimization :: Test
testDfaMinimization = "Resulting DFA is minimized" ~:
  TestList[
    dfaMinimization (excessDFA) ~?= 
    DFA {dstart = 0, 
         dstates = Set.fromList [0,1,2],
         daccept = Set.fromList [1],
         dtransition = Map.fromList [((0,'0'),0),
                                     ((0,'1'),1),
                                     ((1,'0'),1),
                                     ((1,'1'),2),
                                     ((2,'0'),2),
                                     ((2,'1'),2)],
         dalphabet = NonEmpty.fromList "01"},

    dfaMinimization (DFA {dstart = 0, 
         dstates = Set.fromList [0,1,2,3],
         daccept = Set.fromList [1],
         dtransition = Map.fromList [((0,'a'),1),
                                     ((1,'a'),2),
                                     ((2,'a'),3),
                                     ((3,'a'),2)],
         dalphabet = return 'a'}) ~?=
    dfaMinimization (dfaConstruction (singleCharNfa 'a')),

    dfaMinimization (DFA {dstart = 0,
                      dstates = Set.fromList [0,1],
                      daccept = Set.empty,
                      dtransition = Map.fromList [((1,'a'),0)],
                      dalphabet = NonEmpty.fromList "ab"}) ~?=
    emptySetDfa (NonEmpty.fromList "ab"),

    dfaMinimization (DFA {dstart = 0,
                          dstates = Set.fromList [0,1,2],
                          daccept = Set.fromList [0,1],
                          dtransition = Map.fromList [((0,'0'),1), ((1,'0'),2),((2,'0'),2)],
                          dalphabet = NonEmpty.fromList "01"}) ~?= 
                     DFA {dstart = 0,
                          dstates = Set.fromList [0,1,2],
                          daccept = Set.fromList [0,1],
                          dtransition = Map.fromList [((0,'0'),1), ((1,'0'),2),((2,'0'),2)],
                          dalphabet = NonEmpty.fromList "01"}
  ]

-- helper function that returns element list index if element is 
-- present in list, -1 is element is absent from list 
getIndex :: [QState] -> QState -> Int 
getIndex list state = case (List.elemIndex state list) of 
                        Nothing -> -1 
                        Just a -> a   

-- takes a dfa and updates states to be numbered in ascending order from 0 
updateStateSet :: DFA -> DFA
updateStateSet d = let states = Set.toAscList $ dstates d
                       statemap = updateState states where
                                  updateState :: [QState] -> Map Int QState
                                  updateState states = foldr (\x -> Map.insert x (getIndex states x)) 
                                                        Map.empty states 
                   in  
                   DFA {dstart = case Map.lookup (dstart d) statemap of 
                                      Nothing -> error "Dstart unmapped"
                                      Just a -> a,
                                 dstates = Set.fromList $ fmap (\(k,v) -> v)
                                          (Map.toList statemap),
                                 daccept = Set.fromList $ fmap 
                                  (\x -> (case (Map.lookup x statemap) of 
                                          Nothing -> error "Accept state unmapped"
                                          Just a -> a)) $ Set.toList $ daccept d,  
                                 dtransition = Map.fromList $ 
                                fmap (\((a,b),c) -> 
                                     (case (Map.lookup a statemap, 
                                            Map.lookup c statemap) of
                                            (Nothing,_) -> error "Transition unmapped"
                                            (_,Nothing) -> error "Transition unmapped"
                                            (Just v1, Just v2) -> ((v1,b),v2))) 
                                $ Map.toList $ dtransition d, 
                                 dalphabet = dalphabet d }
                   
-- takes a dfa and the list of states of the dfa and deletes
-- all that are unreachable for any transition 
deleteUnreachable :: DFA -> [QState] -> DFA
deleteUnreachable d [] = d
deleteUnreachable d @states(x:xs) = 
  if ((not $ inwardTransition x $ dtransition d) && not (x == dstart d)) 
    then deleteUnreachable (DFA {dstart = dstart d,
                                 dstates = Set.delete x (dstates d),
                                 daccept = daccept d,  
                                 dtransition = Map.fromList $ deleteKey x $ Map.toList $ dtransition d, 
                                 dalphabet = dalphabet d }) xs 
    else deleteUnreachable d xs 

testDeleteUnreachable :: Test
testDeleteUnreachable = "Unreachable states deleted from resulting DFA" ~:
  TestList[
    deleteUnreachable (unreachableDFA) (Set.toList $ dstates unreachableDFA) ~?= emptySetDfa (NonEmpty.fromList "ab"),
    deleteUnreachable (unreachableDFA2) (Set.toList $ dstates unreachableDFA2) ~?= excessDFA 
  ]


-- delete any (QState, Char) pair where QState is k 
deleteKey :: QState -> [((QState, Char), QState)] -> [((QState, Char), QState)] 
deleteKey k translist = List.filter (\((a,b),c) -> not (a == k)) translist 

testDeleteKey :: Test
testDeleteKey = "Deletes matching keys" ~:
  TestList[
    deleteKey 3 [((3,'a'),2)] ~?= [],
    deleteKey 3 [((3,'a'),2),((3,'b'),1),((2,'a'),3)] ~?= [((2,'a'),3)],
    deleteKey 3 [((2,'a'),4),((3,'a'),2)] ~?= [((2,'a'),4)]
  ]

-- takes a state and a transition mapping and returns bool indicating
-- whether any transitions lead to this state  
inwardTransition :: QState -> Dtransition -> Bool 
inwardTransition s transmap = elem s (Map.elems $ Map.filterWithKey (\(k,_) _ -> k /= s) transmap) 

testInwardTransition :: Test 
testInwardTransition = "Identifies inward transition correctly" ~:
  TestList[
    inwardTransition 3 (Map.fromList [((2,'0'),3)]) ~?= True, 
    inwardTransition 3 (Map.fromList [((3,'0'),2)]) ~?= False,
    inwardTransition 3 (Map.fromList []) ~?= False,
    inwardTransition 3 (Map.fromList[((2,'0'),1)]) ~?= False,
    inwardTransition 3 (Map.fromList [((2,'0'),3),((2,'1'),3)]) ~?= True,
    inwardTransition 3 (Map.fromList [((2,'0'),5),((2,'1'),3)]) ~?= True,
    inwardTransition 3 (Map.fromList [((2,'0'),5),((2,'1'),3),((2,'2'),1)]) ~?= True,
    inwardTransition 3 (Map.fromList [((2,'0'),5),((2,'1'),4)]) ~?= False
  ]

-- takes a list of states and returns a list of all unique state pairs 
allPairs :: [QState] -> [(QState,QState)]
allPairs states = [(s1,s2) | s1 <- states, s2 <- states, s1 < s2]

testAllPairs :: Test
testAllPairs = "Returns all unique pairs in list" ~:
  TestList[
    allPairs [1,2,3,4,5] ~?= [(1,2),(1,3),(1,4),(1,5),(2,3),(2,4),(2,5),(3,4),(3,5),(4,5)],
    allPairs [1] ~?= [],
    allPairs [1,2] ~?= [(1,2)],
    allPairs [] ~?= []
  ]

-- iterates through all unique pairs of states and merges indistinguishable pairs
-- in dfa 
mergePair :: DFA -> [(QState,QState)] -> DFA
mergePair d [] = d 
mergePair d (x:xs) =  let newd = mergeIndistinct d (fst x) (snd x) in
                          if (newd == d) 
                          then mergePair d xs -- try next pair in dfa d
                          else mergePair newd $ allPairs $ Set.toList $ dstates newd

-- takes two states and a list of transitions and outward transitions of s2 to s1 
addOutward :: QState -> QState-> [((QState, Char), QState)] -> [((QState, Char), QState)] 
addOutward s1 s2 translist = translist ++ (List.map (\((a,b),c) -> ((a,b),s1)) $
                            List.filter (\((a,b),c) -> (c == s2)) translist) 

-- takes a dfa and two states and merges states if they are indistinct
mergeIndistinct :: DFA -> QState -> QState -> DFA
mergeIndistinct d x1 x2 = if indistinct d x1 x2 
                          then  DFA {dstart = dstart d,
                                     dstates = Set.delete x2 (dstates d),
                                     daccept = Set.delete x2 $ daccept d,  
                                     dtransition = Map.fromList (addOutward x1 x2 $ 
                                                   deleteKey x2 (Map.toList (dtransition d))), 
                                     dalphabet = dalphabet d}
                          else d 

testMergeIndistinct :: Test
testMergeIndistinct = "Merges indistinct states" ~:
  TestList[
    mergeIndistinct excessDFA 2 3 ~?= DFA {dstart = 0, 
                 dstates = Set.fromList [0,1,2,4,5],
                 daccept = Set.fromList [2,4],
                 dtransition = Map.fromList [((0,'0'),1),
                                             ((0,'1'),2),
                                             ((1,'0'),0),
                                             ((1,'1'),2),
                                             ((2,'0'),4),
                                             ((2,'1'),5),
                                             ((4,'0'),4),
                                             ((4,'1'),5),
                                             ((5,'0'),5),
                                             ((5,'1'),5)],
                 dalphabet = NonEmpty.fromList "01"}  
  ]

-- Repeatedly partition states by where their transitions lead
-- in the current partition in order to determine lists
-- of indistinguishable states
partitionQs :: DFA -> [[QState]] -> [[QState]]
partitionQs dfa l = 
    let newPartition = concatMap (\p -> repartition dfa p l) l in
    if newPartition == l then l
      else partitionQs dfa newPartition
    where 
    -- Given a list of states, and a list of current partitions,
    -- repartition them based on where their transitions lead in the
    -- current partition of all states
    repartition :: DFA -> [QState] -> [[QState]] -> [[QState]]
    repartition dfa p l = 
      let nxts = nexts <$> p
          sorts = List.sortBy (compare `on` fst) nxts
          groups = List.groupBy ((==) `on` fst) sorts
          qGroups = fmap (fmap snd) groups
          in qGroups
      where 
        nexts q = 
          let ab = dalphabet dfa
              transition = dtransition dfa
          in ([pGroup (Map.lookup (q,x) (dtransition dfa)) l 
              | x <- NonEmpty.toList ab], q)

        pGroup (Just q') l = findIndex (elem q') l
        pGroup Nothing _ = Nothing

-- Use the moore reduction algorithm 
-- to calculate sets of indistinguishable states
mooreReduction :: DFA -> [[QState]]
mooreReduction dfa = 
  let qs = Set.toList (dstates dfa)
      accepts = [q | q <- qs, Set.member q (daccept dfa)]
      rejects = qs \\ accepts
      initPartition = [accepts, rejects] in 
  partitionQs dfa initPartition

-- Finds indistinguishable states and replaces eac
mergeIndistinguishable :: DFA -> Maybe DFA
mergeIndistinguishable dfa = do
  let dls = mooreReduction dfa
  let q0 = Set.size (dstates dfa)
  let pairing = List.zip [q0..List.length dls + q0] dls
  let mapping = Map.fromList $ concatMap (\(i,l) -> [(q,i) | q <- l]) pairing
  let states = Set.fromList (fst <$> pairing)
  acceptList <- mapM (\a -> Map.lookup a mapping) $ Set.toList (daccept dfa)
  start <- Map.lookup (dstart dfa) mapping 
  let transList = Map.toList (dtransition dfa)
  transitionKeys <- mapM (\(a,c) -> (\x -> (x,c)) <$> (Map.lookup a mapping)) 
                    (fmap fst transList)
  transitionValues <- mapM (\a -> Map.lookup a mapping) 
                      (fmap snd transList)
  let transition = Map.fromList (List.zip transitionKeys transitionValues)
  return DFA {
    dstart = start,
    dstates = states,
    daccept = Set.fromList acceptList,
    dtransition = transition,
    dalphabet = dalphabet dfa}

-- determine if states are equivalent
-- states must both accept or both reject,
-- and their transitions either lead to the same states or to each other
indistinct :: DFA -> QState -> QState -> Bool
indistinct d1 s1 s2 = 
  let accepts = daccept d1 in
  Set.member s1 accepts == Set.member s2 accepts
    && transitionsIndistinct d1 s1 s2 
  where
    transitionsIndistinct :: DFA -> QState -> QState -> Bool 
    transitionsIndistinct dfa s1 s2 = foldr matches True ab where 
      ab = dalphabet d1
      matches x acc = 
        let transitions = dtransition dfa in
        case (Map.lookup (s1,x) transitions, Map.lookup (s2,x) transitions) of
          (Just a, Just b) -> acc && (a == b || (a == s2 && b == s1))
          _ -> False 

testIndistinct :: Test
testIndistinct = "Determines if states are indistinct" ~:
  TestList[
    indistinct excessDFA 2 3 ~?= True,
    indistinct excessDFA 1 2 ~?= False,
    indistinct excessDFA 3 5 ~?= False
  ]

-- return True when r matches the empty string
nullable :: RegExp -> Bool
nullable Empty       = True
nullable (Star _)    = True
nullable (Alt r1 r2) = nullable r1 || nullable r2
nullable (Seq r1 r2) = nullable r1 && nullable r2
nullable _           = False

-- |  Takes a regular expression `r` and a character `c`,
-- and computes a new regular expression that accepts word `w` if `cw` is
-- accepted by `r`.
deriv :: RegExp -> Char -> RegExp
deriv Empty c                = Void
deriv (Char cs) c            = if elem c cs then Empty else Void
deriv (Alt Empty r2) c       = deriv r2 c
deriv (Alt r1 Empty) c       = deriv r1 c
deriv (Alt r1 r2) c          = rAlt (deriv r1 c) (deriv r2 c)
deriv (Seq Empty r2) c       = deriv r2 c
deriv (Seq r1 Empty) c       = deriv r1 c
deriv (Seq r1 r2) c          = let d = deriv r1 c in
                               if nullable r1 then
                                (d `rSeq` r2) `rAlt` (deriv r2 c)
                               else
                                (d `rSeq` r2)
deriv (Star r) c             = deriv r c `rSeq` rStar r
deriv Void _ = Void

testDeriv :: Test
testDeriv = "test computing regex derivatives" ~:
  TestList [
    deriv (rSeq (rAlt (rChar "1") Empty) (rChar "0")) '0' ~?= Empty,
    deriv (rSeq (rStar (rChar "1")) (rChar "0")) '0' ~?= Empty,
    deriv (rSeq (rChar "1") (rChar "0")) '0' ~?= Void,
    deriv (rSeq (rStar (rChar "1")) (rStar (rChar "0"))) '1' ~?=
      rSeq (rStar (rChar "1")) (rStar (rChar "0")),
    deriv (rStar (rSeq (rChar "0") (rStar (rChar "0")))) '0' ~?=
      (rSeq (rStar (rChar "0")) (rStar (rSeq (rChar "0") (rStar (rChar "0")))))
  ]

-- Constructs DFA by determining the regex derivative for each symbol 
-- at the current regex.
-- Each regex is associated with a state and equivalent regexes are the same state.
brzozowskiStateConstruction :: Alpha -> Maybe RegExp -> State (DFASt (RegExp)) ()
brzozowskiStateConstruction ab Nothing  = return ()
brzozowskiStateConstruction ab (Just r) = do     
  dst <- get
  let qCharPairs = (\c -> (r,c)) <$> ab
  derivs <- sequence $ addTransition deriv <$> qCharPairs
  sequence_ $ brzozowskiStateConstruction ab <$> derivs
  return ()

-- Construct a DFA directly from a regular expression
-- uses the Brzozowski Derivative method
brzozowskiConstruction :: RegExp -> DFA
brzozowskiConstruction r = 
  let ab = alpha r
      dst = execState (brzozowskiStateConstruction ab (Just r)) (initDfaSt ab)
      accepts = getAcceptStates nullable (qCorr dst)
  in dfaMinimization $ withAccepts accepts (getDfa dst)

test :: IO ()
test = do
    runTestTT $ TestList [testDfaConstruction, testThompsonNfaConstruction, testDfaMinimization,
                          testDeleteUnreachable, testInwardTransition, testDeleteKey,
                          testAllPairs, testIndistinct, testMergeIndistinct, testDeriv ]
    return ()
