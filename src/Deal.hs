{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}

module Deal (TestDeal(..),run2,runPool2,getInits,runDeal,ExpectReturn(..)
            ,calcDueFee,applicableAdjust,performAction,queryDeal
            ,setFutureCF,populateDealDates
            ,calcTargetAmount,td, updateLiqProvider, accrueLiqProvider) where

import qualified Accounts as A
import qualified Asset as P
import qualified Expense as F
import qualified Liability as L
import qualified CreditEnhancement as CE
import qualified Waterfall as W
import qualified Cashflow as CF
import qualified Assumptions as AP
import qualified AssetClass.Mortgage as ACM
import qualified Call as C
import Stmt
import Lib
import Util
import Types
import Revolving

import qualified Data.Map as Map
import qualified Data.Time as T
import qualified Data.Set as S
import qualified Control.Lens as LS
import Data.List
import Data.Fixed
import Data.Maybe
import Data.Time.Clock
import Data.Aeson hiding (json)
import qualified Data.Aeson.Encode.Pretty as Pretty
import Language.Haskell.TH
import Data.Aeson.TH
import Data.Aeson.Types

import Debug.Trace
debug = flip trace


class SPV a where
  getBondByName :: a -> Maybe [String] -> Map.Map String L.Bond
  getBondBegBal :: a -> String -> Balance
  getBondStmtByName :: a -> Maybe [String] -> Map.Map String (Maybe Statement)
  getFeeByName :: a -> Maybe [String] -> Map.Map String F.Fee
  getAccountByName :: a -> Maybe [String] -> Map.Map String A.Account
  

class DealDates a where 
  getClosingDate :: a -> Date
  getFirstPayDate :: a -> Date

-- data PoolType = P.Pool | MultAsset 

data TestDeal a = TestDeal {
  name :: String
  ,status :: DealStatus
  ,dates :: DateDesp
  ,accounts :: Map.Map String A.Account
  ,fees :: Map.Map String F.Fee
  ,bonds :: Map.Map String L.Bond
  ,pool ::  P.Pool a -- P.Mortgage
  ,waterfall :: Map.Map W.ActionWhen W.DistributionSeq
  ,collects :: [W.CollectionRule]
  ,call :: Maybe [C.CallOption]
  ,liqProvider :: Maybe (Map.Map String CE.LiqFacility)
  ,custom:: Maybe (Map.Map String CustomDataType)
  ,triggers :: Maybe (Map.Map WhenTrigger [(Trigger,TriggerEffect)])
  ,overrides :: Maybe [OverrideType]
} deriving (Show)

instance SPV (TestDeal a) where
  getBondByName t bns
    = case bns of
         Nothing -> bonds t
         Just _bns -> Map.filterWithKey (\k _ -> S.member k (S.fromList _bns)) (bonds t)

  getBondStmtByName t bns
    = Map.map L.bndStmt bndsM
      where
      bndsM = Map.map L.consolStmt $ getBondByName t bns

  getBondBegBal t bn 
    = case L.bndStmt b of
        Just (Statement stmts) -> getTxnBegBalance $ head stmts -- `debug` ("Getting beg bal"++bn++"Last smt"++show (head stmts))
        Nothing -> L.bndBalance b  -- `debug` ("Getting beg bal nothing"++bn)
        where
            b = bonds t Map.! bn

  getFeeByName t fns
    = case fns of
         Nothing -> fees t
         Just _fns -> Map.filterWithKey (\k _ ->  S.member k (S.fromList _fns)) (fees t)
  
  getAccountByName t ans
    = case ans of
         Nothing -> accounts t
         Just _ans -> Map.filterWithKey (\k _ ->  S.member k (S.fromList _ans)) (accounts t)

instance DealDates DateDesp where 
  getClosingDate (PatternInterval _m)
    = let 
        (sd,dp,ed) = _m Map.! ClosingDate 
      in 
         sd
         
  getClosingDate (CustomDates _ _ cd _) = cd

  getClosingDate (FixInterval _m _p1 _p2) = _m Map.! ClosingDate

  getClosingDate (PreClosingDates _ x _ _ _ _) = x

  getClosingDate (CurrentDates (_,cd) _ _ _ _ ) = cd

  getFirstPayDate (PatternInterval _m) 
    = let 
        (sd,dp,ed) = _m Map.! FirstPayDate
      in 
         sd
  
  getFirstPayDate (CustomDates _ _ _ bActions )
    = getDate $ head bActions
  
  getFirstPayDate (FixInterval _m _p1 _p2)  
    = _m Map.! FirstPayDate
  
  getFirstPayDate (PreClosingDates _ _ _ _ _ (fp,_)) = fp
  
  getFirstPayDate (CurrentDates _ _ _ _ (cpay,_)) = cpay

testPre :: P.Asset a => Date -> TestDeal a -> Pre -> Bool
testPre d t p =
  case p of
    Types.And p1 p2 -> testPre d t p1 && testPre d t p1
    Or p1 p2 -> testPre d t p1 || testPre d t p1
    IfZero s -> queryDeal t s == 0.0 -- `debug` ("S->"++show(s)++">>"++show((queryDeal t s)))
    IfGT s amt -> queryDeal t s > amt
    IfGET s amt -> queryDeal t s >= amt
    IfLT s amt -> queryDeal t s < amt
    IfLET s amt -> queryDeal t s <= amt
    IfGTInt s amt -> queryDealInt t s d > amt
    IfGETInt s amt -> queryDealInt t s d >= amt
    IfLTInt s amt -> queryDealInt t s d < amt
    IfLETInt s amt -> queryDealInt t s d <= amt
    IfEqInt s amt -> queryDealInt t s d == amt
    IfEqBal s amt -> queryDeal t s == amt
    IfAfterDate _d -> d > _d
    IfBeforeDate _d -> d < _d
    IfAfterOnDate _d -> d >= _d
    IfBeforeOnDate _d -> d <= _d
    IfDealStatus st -> status t == st

performAction :: P.Asset a => Date -> TestDeal a -> (Maybe Pre, W.Action) -> TestDeal a
performAction d t (Just _pre, _action)
  | testPre d t _pre = performAction d t (Nothing, _action)
  | otherwise  = t

performAction d t@TestDeal{accounts=accMap} (Nothing, W.Transfer an1 an2) =
  t {accounts = accMapAfterDeposit}
  where
    sourceAcc = accMap Map.! an1
    transferAmt = max 0 (A.accBalance sourceAcc)
    comment = Transfer an1 an2
    accMapAfterDraw = Map.adjust (A.draw transferAmt d comment ) an1 accMap
    accMapAfterDeposit = Map.adjust (A.deposit transferAmt d  comment) an2 accMapAfterDraw

performAction d t@TestDeal{accounts=accMap} (Nothing, W.TransferBy limit an1 an2) =
  t {accounts = accMapAfterDeposit}  -- `debug` ("ABCD "++show(d))
  where
    sourceAcc = accMap Map.! an1
    targetAcc = accMap Map.! an2 -- `debug` ("Target>>"++an2)
    formulaAmount = case limit of 
                      W.DuePct r -> r * A.accBalance sourceAcc
                      W.DueCapAmt a -> min a (A.accBalance sourceAcc)
                      W.DS ds -> queryDeal t ds
                      W.Formula W.ABCD -> max 
                                            ((queryDeal t CumulativePoolDefaultedBalance) + 
                                               (negate (queryTxnAmt targetAcc (Transfer an2 an1))) +
                                               (negate (queryTxnAmt sourceAcc (Transfer an1 an2))))
                                          0

    transferAmt = min formulaAmount (A.accBalance sourceAcc) -- `debug` ("already transfer amt"++show(queryStmtAmt (A.accStmt sourceAcc) ("To:"++an2++"|ABCD") ))

    accMapAfterDraw = Map.adjust (A.draw transferAmt d (Transfer an1 an2)) an1 accMap
    accMapAfterDeposit = Map.adjust (A.deposit transferAmt d (Transfer an1 an2)) an2 accMapAfterDraw

performAction d t@TestDeal{accounts=accMap} (Nothing, W.TransferReserve meetAcc sa ta)=
    t {accounts = accMapAfterTransfer }
  where
    sourceAcc = accMap Map.! sa 
    targetAcc = accMap Map.! ta
    sourceAccBal = A.accBalance sourceAcc
    targetAccBal = A.accBalance targetAcc 
    transferAmt = 
        case meetAcc of 
             W.Source ->
                 let 
                   sourceTarBal = calcTargetAmount t d sourceAcc
                 in 
                   max (sourceAccBal - sourceTarBal ) 0
             W.Target ->
                 let 
                   targetBal = calcTargetAmount t d targetAcc
                   transferAmtTarget = max (targetBal - targetAccBal) 0 -- `debug` ("Target balance ->> "++show(targetBal))
                 in 
                   min transferAmtTarget sourceAccBal

    accMapAfterTransfer
      = case transferAmt of
          0 -> accMap
          amt ->  Map.adjust (A.draw amt d (Transfer sa ta)) sa  $ 
                  Map.adjust (A.deposit amt d (Transfer sa ta)) ta $ accMap

performAction d t@TestDeal{fees=feeMap} (Nothing, W.PayFee ans fns) =
  t {accounts = accMapUpdated, fees = feeMapUpdated}
  where
    accMap = getAccountByName t (Just ans)

    feesToPay = map (feeMap Map.!) fns
    feeDueAmts = map F.feeDue feesToPay  

    accNList = Map.toList accMap -- `debug` ("Show Fee with Due "++show(feeDueAmts))
    availBalLst = [ (n,A.accBalance x) | (n,x) <- accNList ]
    availAccBals = map snd availBalLst
    availAccNames = map fst availBalLst
    accList = map (accMap Map.!) ans

    availBal = sum availAccBals

    actualPaidOut = min availBal $ sum feeDueAmts -- `debug` ("Fee Due Amounts"++show(feeDueAmts))
    feesAmountToBePaid = zip feesToPay  $ prorataFactors feeDueAmts availBal
    feesPaid = map (\(f,amt) -> F.payFee d amt f) feesAmountToBePaid

    feeMapUpdated = Map.union (Map.fromList $ zip fns feesPaid) feeMap

    accsAfterPay = A.supportPay accList d actualPaidOut (SeqPayFee fns ,SeqPayFee fns)  
    accMapUpdated = Map.union (Map.fromList (zip ans accsAfterPay)) (accounts t)


performAction d t@TestDeal{fees=feeMap} (Nothing, W.PayFeeBy limit ans fns) =
  t {accounts = accMapUpdated, fees = feeMapUpdated}
  where
    accMap = getAccountByName t (Just ans)
    feesToPay = map (feeMap Map.!) fns
    feeDueAmts = case limit of
                  (W.DuePct pct) -> map (\x -> pct * (F.feeDue x) ) feesToPay
                  (W.DueCapAmt amt) -> map (\x -> (min (F.feeDue x) amt)) feesToPay

    accNList = Map.toList accMap
    availBalLst = [ (n,A.accBalance x) | (n,x) <- accNList]
    availAccBals = map snd availBalLst
    availAccNames = map fst availBalLst
    accList = map (accMap Map.!) ans

    availBal = sum availAccBals

    actualPaidOut = min availBal $ sum feeDueAmts
    feesAmountToBePaid = zip feesToPay  $ prorataFactors feeDueAmts availBal
    feesPaid = map (\(f,amt) -> F.payFee d amt f) feesAmountToBePaid

    feeMapUpdated = Map.union (Map.fromList $ zip fns feesPaid) feeMap

    accsAfterPay = A.supportPay accList d actualPaidOut (SeqPayFee fns,SeqPayFee fns)  
    accMapUpdated = Map.union (Map.fromList (zip ans accsAfterPay)) (accounts t)

performAction d t@TestDeal{bonds=bndMap,accounts=accMap} (Nothing, W.PayInt an bnds) =
  t {accounts = accMapAfterPay, bonds = bndMapUpdated}
  where
    acc = accMap Map.! an

    availBal = A.accBalance acc
    bndsToPay = map (bndMap Map.!) bnds
    bndsWithDue = filter (\x -> L.bndDueInt x > 0) $ map (calcDueInt t d) bndsToPay

    bndsDueAmts = map L.bndDueInt bndsWithDue
    bndsNames = map L.bndName bndsWithDue

    actualPaidOut = min availBal $ sum bndsDueAmts -- `debug` ("due mats"++ show bndsDueAmts ++">>"++ show availBal)
    bndsAmountToBePaid = zip bndsWithDue $ prorataFactors bndsDueAmts availBal -- `debug` ("prorata"++ show (prorataFactors bndsDueAmts availBal) )

    bndsPaid = map (\(l,amt) -> L.payInt d amt l) bndsAmountToBePaid

    bndMapUpdated =   Map.union (Map.fromList $ zip bndsNames bndsPaid) bndMap
    comment = PayInt bnds Nothing
    accMapAfterPay = Map.adjust 
                       (A.draw actualPaidOut d comment)
                       an
                       accMap

performAction d t (Nothing, W.PayTillYield an bnds) =
    performAction d t (Nothing, W.PayInt an bnds)

performAction d t@TestDeal{bonds=bndMap,accounts=accMap} (Nothing, W.PayResidual Nothing an bndName) =
  t {accounts = accMapAfterPay, bonds = bndMapAfterPay}
  where
    availBal = A.accBalance $ accMap Map.! an
    accMapAfterPay = Map.adjust (A.draw availBal d (PayYield bndName Nothing)) an accMap
    bndMapAfterPay = Map.adjust (L.payYield d availBal) bndName bndMap

performAction d t@TestDeal{fees=feeMap,accounts=accMap} (Nothing, W.PayFeeResidual limit an feeName) =
  t {accounts = accMapAfterPay, fees = feeMapAfterPay}
  where
    availBal = A.accBalance $ accMap Map.! an
    paidOutAmt = case limit of
                   Just (W.DuePct pct) ->  pct * availBal
                   Just (W.DueCapAmt cap) ->  min cap availBal
                   Nothing -> availBal
    accMapAfterPay = Map.adjust (A.draw paidOutAmt d (PayFeeYield feeName)) an accMap
    feeMapAfterPay = Map.adjust (F.payFee d paidOutAmt) feeName feeMap

-- ^ pay bond till its balance as pct of total balance
performAction d t@TestDeal{bonds=bndMap,accounts=accMap} (Nothing, W.PayPrinBy (W.RemainBalPct pct) an bndName)=  --Need to replace with formula
  t {accounts = accMapAfterPay, bonds = bndMapAfterPay}
  where
    availBal = A.accBalance $ accMap Map.! an
    targetBnd = bndMap Map.! bndName
    targetBndBal = L.bndBalance targetBnd

    otherBndBal = queryDeal t CurrentBondBalance - targetBndBal

    _pct = fromRational pct
    dueAmount = (1/(1-_pct)) * (targetBndBal * (1-_pct) - (_pct * otherBndBal))
    actAmount = min availBal $ max dueAmount 0

    accMapAfterPay = Map.adjust
                        (A.draw actAmount d Empty) --TODO
                        an
                        accMap
    bndMapAfterPay = Map.adjust (L.payPrin d actAmount) bndName bndMap

performAction d t@TestDeal{bonds=bndMap,accounts=accMap} (Nothing, W.PayPrinBy (W.DS ds) an bndName)=  --Need to replace with formula
  t {accounts = accMapAfterPay, bonds = bndMapAfterPay}
  where
    availBal = A.accBalance $ accMap Map.! an
    targetBnd = bndMap Map.! bndName

    patchedDs = patchDateToStats d ds 
    payAmount = min availBal (queryDeal t patchedDs) -- `debug` ("Query with "++show (patchedDs))

    accMapAfterPay = Map.adjust
                        (A.draw payAmount d (TxnComments [PayPrin [bndName] Nothing,UsingDS ds])) 
                        an
                        accMap  -- `debug` ("payOutAmt"++show (queryDeal t patchedDs))
    bndMapAfterPay = Map.adjust 
                       (L.payPrin d payAmount) 
                       bndName $
                       Map.adjust (calcDuePrin t d) bndName bndMap -- `debug` ("Actual PayAmount"++show payAmount)


performAction d t@TestDeal{bonds=bndMap,accounts=accMap} (Nothing, W.PayPrin an bnds) =
  t {accounts = accMapAfterPay, bonds = bndMapUpdated} -- `debug` ("Bond Prin Pay Result"++show(bndMapUpdated))
  where
    acc = accMap Map.! an

    bndsToPay = filter (\x -> L.bndBalance x > 0) $ map (bndMap Map.!) bnds
    availBal = A.accBalance acc
    -- TODO  add filter lockout bonds here
    bndsWithDue = map (calcDuePrin t d) bndsToPay  --
    bndsDueAmts = map L.bndDuePrin bndsWithDue

    actualPaidOut = min availBal $ sum bndsDueAmts -- `debug` ("bonds totoal due ->"++show(bndsDueAmts))
    bndsAmountToBePaid = zip bndsWithDue (prorataFactors bndsDueAmts availBal)
    bndsPaid = map (\(l,amt) -> L.payPrin d amt l) bndsAmountToBePaid --  `debug` ("pay prin->>>To"++show(bnds))

    bndMapUpdated =  Map.union (Map.fromList $ zip bnds bndsPaid) bndMap
    accMapAfterPay = Map.adjust (A.draw actualPaidOut d (PayPrin bnds Nothing)) an accMap

performAction d t@TestDeal{accounts=accMap, bonds=bndMap} (Nothing, W.PayPrinResidual an bnds) = 
  t {accounts = accMapAfterPay, bonds = bndMapUpdated} -- `debug` ("Bond Prin Pay Result"++show(bndMapUpdated))
  where
    acc = accMap Map.! an

    bndsToPay = filter (\x -> L.bndBalance x > 0) $ map (bndMap Map.!) bnds
    availBal = A.accBalance acc
    -- TODO  add filter lockout bonds here
    bndsDueAmts = map L.bndBalance bndsToPay

    actualPaidOut = min availBal $ sum  bndsDueAmts -- `debug` ("bonds totoal due ->"++show(bndsDueAmts))
    bndsAmountToBePaid = zip bndsToPay (prorataFactors bndsDueAmts availBal)
    bndsPaid = map (\(l,amt) -> L.payPrin d amt l) bndsAmountToBePaid --  `debug` ("pay prin->>>To"++show(bnds))

    bndMapUpdated =  Map.union (Map.fromList $ zip bnds bndsPaid) bndMap
    accMapAfterPay = Map.adjust (A.draw actualPaidOut d (PayPrin bnds Nothing)) an accMap

performAction d t@TestDeal{accounts=accMap} (Nothing, W.LiquidatePool lm an) =
  t {accounts = accMapAfterLiq } -- TODO need to remove assets
  where
    liqAmt = calcLiquidationAmount lm (pool t) d
    accMapAfterLiq = Map.adjust (A.deposit liqAmt d (LiquidationProceeds liqAmt)) an accMap

performAction d t@TestDeal{fees=feeMap} (Nothing, W.CalcFee fns) 
  = t {fees = Map.union newFeeMap feeMap }
  where 
    newFeeMap = Map.map
                  (calcDueFee t d) $
                  getFeeByName t (Just fns)

performAction d t@TestDeal{bonds=bndMap} (Nothing, W.CalcBondInt bns) 
  = t {bonds = Map.union newBondMap bndMap}
  where 
    newBondMap = Map.map 
                  (calcDueInt t d) $
                  getBondByName t (Just bns)

performAction d t@TestDeal{accounts=accs,liqProvider = Just _liqProvider} (Nothing, W.LiqSupport limit pName an)
  = t { accounts = newAccMap, liqProvider = Just newLiqMap } -- `debug` ("Using LImit"++ show limit)
  where 
      _transferAmt = case limit of 
                      Nothing -> 0 -- `debug` ("limit on nothing"++ show limit)
                      Just (W.DS (ReserveAccGap [an])) -> queryDeal t (ReserveAccGapAt d [an]) -- `debug` ("Query Gap"++ show (queryDeal t (ReserveAccGapAt d [an])))
                      Just (W.DS ds) -> queryDeal t ds -- `debug` ("hit with ds"++ show ds)
                      _ -> error "Failed on formula passed" -- `debug` ("limit on last"++ show limit)
      transferAmt = case CE.liqBalance $  _liqProvider Map.! pName of 
                       Nothing -> _transferAmt
                       Just _availBal -> min _transferAmt _availBal  -- `debug` ("transfer amt"++ show _transferAmt )
 --     transferAmt = min _transferAmt $ CE.liqBalance $  _liqProvider Map.! pName  -- `debug` ("_tAmft"++show _transferAmt)
      newAccMap = Map.adjust (A.deposit transferAmt d (LiquidationSupport pName)) an accs
      newLiqMap = Map.adjust (CE.draw transferAmt d ) pName _liqProvider 

performAction d t@TestDeal{fees=feeMap,liqProvider = Just _liqProvider} (Nothing, W.LiqPayFee limit pName fn)
  = t { fees = newFeeMap, liqProvider = Just newLiqMap }
  where 
      _transferAmt = case limit of 
                      Nothing -> 0 
                      Just (W.DS (CurrentDueFee [fn]))
                        -> queryDeal t (CurrentDueFee [fn])
                      _ -> 0
      transferAmt = case CE.liqBalance $  _liqProvider Map.! pName of 
                       Nothing -> _transferAmt
                       Just _availBal -> min _transferAmt _availBal
     -- transferAmt = min _transferAmt $ CE.liqBalance $  _liqProvider Map.! pName
      newFeeMap = Map.adjust (F.payFee d transferAmt) fn feeMap
      newLiqMap = Map.adjust (CE.draw transferAmt d ) pName _liqProvider 


performAction d t@TestDeal{bonds=bndMap,liqProvider = Just _liqProvider} (Nothing, W.LiqPayBond limit pName bn)
  = t { bonds = newBondMap, liqProvider = Just newLiqMap }
  where 
      _transferAmt = case limit of 
                      Nothing -> 0 
                      Just (W.DS (CurrentDueBondInt [bn]))
                        -> queryDeal t (CurrentDueBondInt [bn])
                      _ -> 0
      transferAmt = case CE.liqBalance $  _liqProvider Map.! pName of 
                       Nothing -> _transferAmt
                       Just _availBal -> min _transferAmt _availBal
      --transferAmt = min _transferAmt $ CE.liqBalance $  _liqProvider Map.! pName
      newBondMap = Map.adjust (L.payInt d transferAmt ) bn bndMap
      newLiqMap = Map.adjust (CE.draw transferAmt d ) pName _liqProvider 


performAction d t@TestDeal{accounts=accs,liqProvider = Just _liqProvider} (Nothing, W.LiqRepay limit an pName)
  = t { accounts = newAccMap, liqProvider = Just newLiqMap }
  where 
      liqDue = CE.liqCredit $ _liqProvider Map.! pName
      transferAmt = case limit of 
                      Nothing -> min liqDue $ A.accBalance $ accs Map.! an
                      _ -> 0 -- to be implement
      newAccMap = Map.adjust (A.draw transferAmt d (LiquidationSupport pName)) an accs
      newLiqMap = Map.adjust (CE.repay transferAmt d ) pName _liqProvider 

performAction d t@TestDeal{accounts=accs,liqProvider = Just _liqProvider} (Nothing, W.LiqYield limit an pName)
  = t { accounts = newAccMap, liqProvider = Just newLiqMap }
  where 
      transferAmt = case limit of 
                      Nothing -> A.accBalance $ accs Map.! an
                      _ -> 0 -- to be implement
      newAccMap = Map.adjust (A.draw transferAmt d (LiquidationSupport pName)) an accs
      newLiqMap = Map.adjust (CE.repay transferAmt d ) pName _liqProvider 

performAction d t@TestDeal{liqProvider = Just _liqProvider} (Nothing, W.LiqAccrue n)
  = t {liqProvider = Just updatedLiqProvider}
    where 
      updatedLiqProvider = Map.adjust (accrueLiqProvider t d ) n _liqProvider

setBondNewRate :: T.Day -> [RateAssumption] -> L.Bond -> L.Bond
setBondNewRate d ras b@(L.Bond _ _ _ ii _ _ _ _ _ _ _ _) 
  = b { L.bndRate = applyFloatRate ii d ras }

getRateAssumptionByIndex :: [RateAssumption] -> Index -> Maybe RateAssumption
getRateAssumptionByIndex ras idx
  = find
      (\case
        (RateCurve _idx _ts) -> (_idx==idx)
        (RateFlat _idx _rval) -> (_idx==idx))
      ras


applyFloatRate :: L.InterestInfo -> T.Day -> [RateAssumption] -> IRate
applyFloatRate (L.Floater idx spd p dc mf mc) d ras
  = case (mf,mc) of
      (Nothing,Nothing) -> _rate
      (Just f,Nothing) -> max f _rate
      (Just f,Just c) -> min c $ max f _rate
      (Nothing,Just c) -> min c _rate
    where
      idx_rate = case ra of 
        Just (RateCurve _idx _ts) -> fromRational $ getValByDate _ts Exc d
        Just (RateFlat _idx _r) ->   _r
        Nothing -> 0.0
      ra = getRateAssumptionByIndex ras idx
      _rate = idx_rate + spd

applicableAdjust :: T.Day -> L.Bond -> Bool
applicableAdjust d (L.Bond _ _ oi (L.Floater _ _ rr _ _ _) _ _ _ _ _ _ _ _ )
  = case rr of 
      L.ByInterval p mStartDate ->
          let 
            epocDate = fromMaybe (L.originDate oi) mStartDate
            diff = T.diffGregorianDurationClip epocDate d
          in
            0 == mod (T.cdMonths diff) (fromIntegral (monthsOfPeriod p))
      L.MonthOfYear monthIndex ->
          let 
            (_,m,_) = T.toGregorian d
          in 
            m == monthIndex

applicableAdjust d (L.Bond _ _ oi (L.Fix _ _ ) _ _ _ _ _ _ _ _ ) = False
applicableAdjust d (L.Bond _ _ oi (L.InterestByYield _ ) _ _ _ _ _ _ _ _ ) = False

setBndsNextIntRate :: TestDeal a -> T.Day -> Maybe [RateAssumption] -> TestDeal a
setBndsNextIntRate t d (Just ras) = t {bonds = updatedBonds}
    where 
        floatBonds = filter (applicableAdjust d) $ Map.elems (bonds t)
        floatBondNames = map L.bndName floatBonds -- `debug` ("Resetting bonds=>"++ show floatBondNames)
        updatedBonds = foldr (Map.adjust (setBondNewRate d ras)) (bonds t) floatBondNames

setBndsNextIntRate t d Nothing = t 

testCall :: P.Asset a => TestDeal a -> T.Day -> C.CallOption -> Bool 
testCall t d opt = 
    case opt of 
       C.PoolBalance x -> queryDeal t FutureCurrentPoolBalance < x
       C.BondBalance x -> queryDeal t CurrentBondBalance < x
       C.PoolFactor x ->  queryDealRate t (FutureCurrentPoolFactor d) < fromRational x -- `debug` ("D "++show d++ "Pool Factor query ->" ++ show (queryDealRate t (FutureCurrentPoolFactor d)))
       C.BondFactor x ->  queryDealRate t BondFactor < fromRational x
       C.OnDate x -> x == d 
       C.AfterDate x -> d > x
       C.And xs -> all (testCall t d) xs
       C.Or xs -> any (testCall t d) xs

testCalls :: P.Asset a => TestDeal a -> Date -> [C.CallOption] -> Bool
testCalls t d [] = False  -- `debug` ("Empty call optns")
testCalls t d opts = any (testCall t d) opts  -- `debug` ("testing call options"++ show opts)

queryTrigger :: P.Asset a => TestDeal a -> WhenTrigger -> [(Trigger,TriggerEffect)]
queryTrigger (TestDeal _ _ _ _ _ _ _ _ _ _ _ _ Nothing _) wt = []
queryTrigger (TestDeal _ _ _ _ _ _ _ _ _ _ _ _ (Just trgsM) _) wt 
  =  Map.findWithDefault [] wt trgsM 

testTrigger :: P.Asset a => TestDeal a -> Date -> Trigger -> Bool 
testTrigger t d trigger = 
  case trigger of 
    -- query balance
    (ThresholdBal Below ds v) -> queryDeal t (patchDateToStats d ds) < v  --  `debug` ("< Above "++show (queryDeal t (patchDateToStats d ds))++"||"++ show v)
    (ThresholdBal EqBelow ds v) -> queryDeal t (patchDateToStats d ds) <= v -- `debug` ("<= Above "++show (queryDeal t (patchDateToStats d ds))++"||"++ show v)
    (ThresholdBal Above ds v) -> queryDeal t (patchDateToStats d ds) > v  --  `debug` ("> Above "++show (queryDeal t (patchDateToStats d ds))++"||"++ show v)
    (ThresholdBal EqAbove ds v) -> queryDeal t (patchDateToStats d ds) >= v -- `debug` (">= Above "++show (queryDeal t (patchDateToStats d ds))++"||"++ show v)
    (ThresholdBalCurve Below ds ts ) -> queryDeal t (patchDateToStats d ds) < fromRational (getValByDate ts Exc d)
    (ThresholdBalCurve EqBelow ds ts ) -> queryDeal t (patchDateToStats d ds) <= fromRational (getValByDate ts Exc d)
    (ThresholdBalCurve Above ds ts ) -> queryDeal t (patchDateToStats d ds) > fromRational (getValByDate ts Exc d)
    (ThresholdBalCurve EqAbove ds ts ) -> queryDeal t (patchDateToStats d ds) >= fromRational (getValByDate ts Exc d)
    -- query rate
    (ThresholdRate Below ds v ) -> queryDealRate t (patchDateToStats d ds) < v
    (ThresholdRate EqBelow ds v ) -> queryDealRate t (patchDateToStats d ds) <= v
    (ThresholdRate Above ds v) -> queryDealRate t (patchDateToStats d ds) > v  -- `debug` ("Running test Trigger" ++ show (patchDateToStats d ds)++">>"++show ds)
    (ThresholdRate EqAbove ds v ) -> queryDealRate t (patchDateToStats d ds) >= v
    (ThresholdRateCurve Below ds ts ) -> queryDealRate t (patchDateToStats d ds) < fromRational (getValByDate ts Exc d)
    (ThresholdRateCurve EqBelow ds ts ) -> queryDealRate t (patchDateToStats d ds) <= fromRational (getValByDate ts Exc d)
    (ThresholdRateCurve Above ds ts ) -> queryDealRate t (patchDateToStats d ds) > fromRational (getValByDate ts Exc d)  -- `debug` ("> Above "++ show (queryDealRate t (patchDateToStats d ds))++"|"++ show (getValByDate ts d) ++"|"++show "DATE"++show d)
    (ThresholdRateCurve EqAbove ds ts ) -> queryDealRate t (patchDateToStats d ds) >= fromRational (getValByDate ts Exc d)
    
    (PassMaturityDate bn) -> let 
                                b@(L.Bond _ _ (L.OriginalInfo _ _ _ mm) _ _ _ _ _ _ _ _ _) = bonds t Map.! bn
                             in 
                                case mm of 
                                  Nothing -> False
                                  Just _d -> L.bndBalance b > 0 && ( d >= _d ) 
    
    AfterDate _d -> d > _d
    AfterOnDate _d -> d >= _d

    (AllTrigger tgs) -> all (testTrigger t d) tgs
    (AnyTrigger tgs) -> any (testTrigger t d) tgs

    Always b -> b
    _  -> error ("Should not happend in deal query"++show trigger)


testTriggers :: P.Asset a => TestDeal a -> Date -> [Trigger] -> Bool
testTriggers t d [] = False
testTriggers t d triggers = any (testTrigger t d) triggers 

runEffects :: P.Asset a => TestDeal a -> Date -> TriggerEffect -> TestDeal a 
runEffects t d te 
  = case te of 
      DealStatusTo _ds -> t {status=_ds} -- `debug` ("changing status to "++show _ds)
      DoAccrueFee fns -> 
        let 
          fset = S.fromList fns
          newFeeMap = Map.mapWithKey 
                            (\k v ->
                              if (S.member k fset) then 
                                (calcDueFee t d v)
                              else 
                                v) 
                            (fees t)
        in 
          t {fees = newFeeMap}  
      _ -> error $ "Failed to match"++show te


runTriggers :: P.Asset a => TestDeal a -> Date -> [(Trigger,TriggerEffect)] -> (TestDeal a,[ResultComponent])
runTriggers t@TestDeal{status=oldStatus} d _trgs = 
    (newDeal, newLogs)
  where 
    triggeredEffects = [ snd x | x <- _trgs, testTrigger t d (fst x) ] -- `debug` ("DEBUG->TG"++show [ testTrigger t d (fst x) | x <- _trgs ])
    newDeal = foldl 
               (\_t _te -> runEffects _t d _te)
               t
               triggeredEffects -- `debug` ("Running Trigger"++show d++show _trgs ++" Effects->"++ show triggeredEffects)
    newStatus = status newDeal -- `debug` ("new Status"++show (status newDeal)++"Old"++show oldStatus)         
    newLogs = if newStatus /= oldStatus then 
                [DealStatusChangeTo d oldStatus newStatus] --`debug` ("Changing status"++show oldStatus++show newStatus++"D->"++show d)
              else 
                []  

  -- TODO in the best case, trigger should only run when the target variable changes
  -- ie. pool factor should be run when the pool collection day
  --     bond factor should be run at the begining or the ending of the waterfall.
  
runCall :: P.Asset a => Date -> [C.CallOption] -> TestDeal a -> TestDeal a
runCall d opts t 
  = if testCalls t d opts then 
      prepareDeal $ foldl (performAction d) t cleanUpActions `debug` ("Called ! "++ show d)
    else
      t
    where
      cleanUpActions = Map.findWithDefault [] W.CleanUp (waterfall t)  --  `debug` ("Running AD"++show(d))

run2 :: P.Asset a => TestDeal a -> CF.CashFlowFrame -> Maybe [ActionOnDate] -> Maybe [RateAssumption] -> Maybe [C.CallOption] -> [ResultComponent] -> (TestDeal a,[ResultComponent])
run2 t@TestDeal{status=Ended} _ _ _ _ log = (prepareDeal t,log) `debug` "Deal Ended"
run2 t _ (Just []) _ _ log  = (prepareDeal t,log)  `debug` "End with Empty ActionOnDate"
run2 t poolFlow (Just (ad:ads)) rates calls log
  | (CF.sizeCashFlowFrame poolFlow == 0) && (queryDeal t  AllAccBalance == 0) 
     = (prepareDeal (foldl (performAction (getDate ad)) t cleanUpActions),log)
  | otherwise
     = case ad of
         PoolCollection d _ ->
             if CF.sizeCashFlowFrame poolFlow > 0 then
               let 
                 (collected_flow,outstanding_flow) = CF.splitCashFlowFrameByDate poolFlow d  EqToLeft
                 accs = depositPoolInflow (collects t) d collected_flow (accounts t) -- `debug` ("Splitting:"++show(d)++"|||"++show(collected_flow))--  `debug` ("Running AD P"++show(d)) --`debug` ("Deposit-> Collection Date "++show(d)++"with"++show(collected_flow))
                 dAfterDeposit = (appendCollectedCF t collected_flow) {accounts=accs}  -- `debug` ("CF size collected"++ show (CF.getTsCashFlowFrame))
                 (dRunWithTrigger0,newLogs0) = runTriggers dAfterDeposit d $ queryTrigger dAfterDeposit EndCollection
                 waterfallToExe = Map.findWithDefault [] W.EndOfPoolCollection (waterfall t)  -- `debug` ("AD->"++show(ad)++"remain ads"++show(length ads))
                 dAfterAction = foldl (performAction d) dRunWithTrigger0 waterfallToExe
                 (dRunWithTrigger1,newLogs1) = runTriggers dAfterAction d $ queryTrigger dAfterAction EndCollectionWF -- `debug` ("Running T end of Collection"++show (queryTrigger dAfterAction EndCollectionWF))
               in 
                 run2 dRunWithTrigger1 outstanding_flow (Just ads) rates calls (log++newLogs0++newLogs1) -- `debug` ("Logs"++ show d++"is"++ show log++">>"++show newLogs0++show newLogs1)
             else
               run2 t (CF.CashFlowFrame []) (Just ads) rates calls log-- `debug` ("pool ends with call"++show calls)
   
         RunWaterfall d _ ->
           case calls of
             Just callOpts ->
                 if testCalls dRunWithTrigger1 d callOpts then 
                   ((prepareDeal (foldl (performAction d) dRunWithTrigger1 cleanUpActions)), log) -- `debug` ("Called ! "++ show d)
                 else
                   run2 dRunWithTrigger1 poolFlow (Just ads) rates calls newLogs -- `debug` ("Not called "++ show d )
             Nothing ->
                run2 dRunWithTrigger1 poolFlow (Just ads) rates Nothing newLogs -- `debug` ("Deal Status"++ show (status dRunWithTrigger1)) -- `debug` ("Call is Nothing")-- `debug` ("Running Waterfall at"++ show d)--  `debug` ("!!!Running waterfall"++show(ad)++"Next ad"++show(head ads)++"PoolFLOW>>"++show(poolFlow)++"AllACCBAL"++show(queryDeal t AllAccBalance))
           where
                (dRunWithTrigger0,newLogs0) = runTriggers t d $ queryTrigger t BeginDistributionWF
                waterfallToExe = Map.findWithDefault 
                                   [] 
                                   (W.DistributionDay (status t)) 
                                   (waterfall t)
   
                dAfterWaterfall = foldl (performAction d) dRunWithTrigger0 waterfallToExe  -- `debug` ("Waterfall>>>"++show(waterfallToExe))
                dAfterRateSet = setBndsNextIntRate dAfterWaterfall d rates  -- `debug` ("Running Rate assumption"++show(rates)) -- `debug` ("After Rate Set")
                (dRunWithTrigger1,newLogs1) = runTriggers dAfterRateSet d $ queryTrigger dAfterRateSet EndDistributionWF  
                newLogs = log++newLogs0 ++ newLogs1
         EarnAccInt d accName ->
           let 
             newAcc = Map.adjust 
                        (\a -> case a of
                                (A.Account _ _ (Just (A.BankAccount _ _ _)) _ _ ) -> 
                                    (A.depositInt a d)  -- `debug` ("int acc"++show accName)
                                (A.Account _ _ (Just (A.InvestmentAccount idx _ _ _)) _ _ ) -> 
                                    let 
                                      rc = getRateAssumptionByIndex (fromMaybe [] rates) idx 
                                    in 
                                      case rc of
                                        Nothing -> a -- `debug` ("error..."++show accName)
                                        Just (RateCurve _ _ts) -> A.depositIntByCurve a _ts d  ) -- `debug` ("int acc"++show accName)
                        accName  
                        (accounts t)
             dAfterInt = t {accounts = newAcc} 
           in 
             run2 dAfterInt poolFlow (Just ads) rates calls log
         
         AccrueFee d feeName -> 
           let 
             newFeeMap = Map.adjust (calcDueFee t d) feeName (fees t)
           in
             run2 (t{fees=newFeeMap}) poolFlow (Just ads) rates calls log
   
         ResetLiqProvider d liqName -> 
           case liqProvider t of 
             Nothing -> run2 t poolFlow (Just ads) rates calls log
             (Just mLiqProvider) 
               -> let 
                    newLiqMap = Map.adjust (updateLiqProvider t d) liqName mLiqProvider
                  in
                    run2 (t{liqProvider =Just newLiqMap}) poolFlow (Just ads) rates calls log

         DealClosed d ->
             let 
               w = Map.findWithDefault [] W.OnClosingDay (waterfall t) 
               newDeal = foldl (performAction d) t w -- `debug` ("ClosingDay Action:"++show w)
             in 
               run2 newDeal poolFlow (Just ads) rates calls log
         ChangeDealStatusTo d s -> 
             run2 (t{status=s}) poolFlow (Just ads) rates calls log

         InspectDS d ds -> 
             let 
               newlog = InspectBal d ds $ queryDeal t (patchDateToStats d ds)
             in 
               run2 t poolFlow (Just ads) rates calls  $ log++[newlog] 
         where
           cleanUpActions = Map.findWithDefault [] W.CleanUp (waterfall t)  -- `debug` ("Running AD"++show(ad))


run2 t (CF.CashFlowFrame []) Nothing Nothing Nothing log
  = run2 t pcf (Just ads) Nothing Nothing log
  where
    (ads,pcf,rcurves,clls) = getInits t Nothing -- `debug` ("Init Done")

run2 t (CF.CashFlowFrame []) _ _ _ log = (prepareDeal t,log) 


calcLiquidationAmount :: LiquidationMethod -> P.Pool a -> Date -> Amount
calcLiquidationAmount alm pool d 
  = case alm of 
      BalanceFactor currentFactor defaultFactor ->
          case P.futureCf pool of 
            Nothing -> 0  -- `debug` ("No futureCF")
            Just _futureCf ->
                let 
                  poolInflow = CF.getEarlierTsCashFlowFrame _futureCf d -- `debug` ("liq:"++show _futureCf++"D"++ show d)
                  earlierTxns = CF.getTxnAsOf _futureCf d
                  currentDefaulBal = sum $ map (\x -> (CF.mflowDefault x) - (CF.mflowRecovery x) - (CF.mflowLoss x)) earlierTxns
                in 
                  case poolInflow of 
                    Nothing -> 0  -- `debug` ("No pool Inflow")
                    Just _ts ->   -- TODO need to check if missing last row
                        (mulBR (CF.mflowBalance _ts) currentFactor) + (mulBR currentDefaulBal defaultFactor) 
                        -- `debug` ("LIQ:"++show poolInflow)

      PV discountRate recoveryPct ->
          case P.futureCf pool of
            Nothing -> 0 
            Just _futureCf ->
                let 
                  futureTxns = CF.getTxnAfter _futureCf d
                  earlierTxns = CF.getTxnAsOf _futureCf d
                  pvCf = sum $ map (\x -> pv2  discountRate  d (CF.getDate x) (CF.tsTotalCash x)) futureTxns 
                  currentDefaulBal = sum $ map (\x -> (CF.mflowDefault x) - (CF.mflowRecovery x) - (CF.mflowLoss x)) earlierTxns
                in 
                  pvCf + mulBI currentDefaulBal recoveryPct

liquidatePool :: LiquidationMethod -> T.Day -> String -> TestDeal a -> TestDeal a
liquidatePool lq d accName t =
  t {accounts = Map.adjust updateFn accName accs} -- `debug` ("Accs->"++show(accs))
  where
     proceeds = calcLiquidationAmount lq (pool t) d
     updateFn = A.deposit proceeds d (LiquidationProceeds proceeds)
     accs = accounts t

data ExpectReturn = DealStatus
                  | DealPoolFlow
                  | DealPoolFlowPricing
                  | DealTxns
                  | ExecutionSummary
                  deriving (Show)

priceBonds :: TestDeal a -> AP.BondPricingInput -> Map.Map String L.PriceResult
priceBonds t (AP.DiscountCurve d dc) = Map.map (L.priceBond d dc) (bonds t)

priceBonds t (AP.RunZSpread curve bond_prices) 
  = Map.mapWithKey 
      (\bn (pd,price)-> L.ZSpread $
                           L.calcZspread 
                             (price,pd) 
                             0
                             (100,0.02) 
                             (L.bndStmt ((bonds t)Map.!bn))
                             curve)
      bond_prices

runDeal :: P.Asset a => TestDeal a -> ExpectReturn -> Maybe AP.ApplyAssumptionType -> Maybe AP.BondPricingInput
        -> (TestDeal a,Maybe CF.CashFlowFrame, Maybe [ResultComponent],Maybe (Map.Map String L.PriceResult))
runDeal t er assumps bpi =
  case er of
    DealStatus ->  (finalDeal, Nothing, Nothing, Nothing)
    DealPoolFlow -> (finalDeal, Just pcf, Nothing, Nothing)
    DealPoolFlowPricing -> (finalDeal, Just pcf, Just ((getRunResult finalDeal)++logs), bndPricing)  -- `debug` ("logs"++show(logs))
  where
    (ads,pcf,rcurves,calls) = getInits t assumps  -- `debug` ("Init Deal"++show (name t)++">> cf length"++show ( P.futureCf (pool t))) -- ("Init in runDeal")
    (finalDeal,logs) = run2 (removePoolCf t) pcf (Just ads) (Just rcurves) calls []  -- `debug` ("Action >>"++show ads)
    bndPricing = case bpi of
                   Nothing -> Nothing   -- `debug` ("pricing bpi with Nothing")
                   Just _bpi -> Just (priceBonds finalDeal _bpi)  -- `debug` ("Pricing with"++show _bpi)

getRunResult :: TestDeal a -> [ResultComponent]
getRunResult t = os_bn_i ++ os_bn_b
  where 
    bs = Map.elems $ bonds t
    os_bn_b = [ BondOutstanding (L.bndName _b) (L.bndBalance _b) (getBondBegBal t (L.bndName _b)) | _b <- bs ]
    os_bn_i = [ BondOutstandingInt (L.bndName _b) (L.bndDueInt _b) (getBondBegBal t (L.bndName _b)) | _b <- bs ]

prepareDeal :: TestDeal a -> TestDeal a
prepareDeal t = 
    t {bonds = Map.map L.consolStmt (bonds t)} -- `debug` ("Consolidation in preparingw")

buildRateCurves :: [RateAssumption]-> [AP.AssumptionBuilder] -> [RateAssumption] 
buildRateCurves rs (assump:assumps) = 
    case assump of 
      AP.InterestRateConstant i f -> 
        buildRateCurves (RateFlat i f:rs) assumps
      AP.InterestRateCurve i ds ->  -- Index [(T.Day, Float)]
        buildRateCurves (RateCurve i (dsToTs ds):rs) assumps
      _ -> buildRateCurves rs assumps    
    where  
        dsToTs ds = IRateCurve $ map (\(d,f) -> TsPoint d f ) ds
buildRateCurves rs [] = rs

buildCallOptions :: Maybe [C.CallOption] -> [AP.AssumptionBuilder] -> Maybe [C.CallOption]
buildCallOptions rs (assump:assumps) =
    case assump of  
      AP.CallWhen opts -> buildCallOptions (Just opts) assumps --`debug` ("assump in build"++show(assumps))
      _ -> buildCallOptions rs assumps

buildCallOptions Nothing [] =  Nothing
buildCallOptions rs [] =  rs


appendCollectedCF :: TestDeal a -> CF.CashFlowFrame -> TestDeal a
appendCollectedCF t (CF.CashFlowFrame []) = t
appendCollectedCF t@(TestDeal { pool = mpool }) cf@(CF.CashFlowFrame _trs)
  = case P.futureCf mpool of 
      Nothing -> t {pool = mpool {P.futureCf = Just cf}}
      Just _p -> t {pool = mpool {P.futureCf = Just (CF.appendCashFlow _p _trs)}}

removePoolCf :: TestDeal a -> TestDeal a
removePoolCf t@(TestDeal {pool = _pool})
  = case P.futureCf _pool of 
      Nothing -> t 
      Just _cf -> t {pool = _pool {P.futureCf = Nothing}}

setFutureCF :: TestDeal a-> CF.CashFlowFrame -> TestDeal a
setFutureCF t cf = 
    t {pool = newPool}
    where 
    _pool = pool t
    newPool = _pool {P.futureCf = Just cf}

populateDealDates :: DateDesp -> (Date,Date,Date,[ActionOnDate],[ActionOnDate],Date)
populateDealDates (CustomDates cutoff pa closing ba) 
  = (cutoff  
    ,closing
    ,getDate (head ba)
    ,pa
    ,ba
    ,(getDate (max (last pa) (last ba))))

populateDealDates (PatternInterval _m) 
  = (cutoff,closing,nextPay,pa,ba,max ed1 ed2) -- `debug` ("PA>>>"++ show pa)
    where 
      (cutoff,dp1,ed1) = _m Map.! CutoffDate
      (nextPay,dp2,ed2) = _m Map.! FirstPayDate 
      (closing,_,_) = _m Map.! ClosingDate
      pa = [ PoolCollection _d "" | _d <- genSerialDatesTill cutoff dp1 ed1 ]
      ba = [ RunWaterfall _d "" | _d <- genSerialDatesTill nextPay dp2 ed2 ]

populateDealDates (PreClosingDates cutoff closing mRevolving end (firstCollect,poolDp) (firstPay,bondDp))
  = (cutoff,closing,firstPay,pa,ba,end) -- `debug` ("POOL A"++show pa) 
    where 
      pa = [ PoolCollection _d "" | _d <- genSerialDatesTill2 IE firstCollect poolDp end ]
      ba = [ RunWaterfall _d "" | _d <- genSerialDatesTill2 IE firstPay bondDp end ]

populateDealDates (CurrentDates (lastCollect,lastPay) mRevolving end (nextCollect,poolDp) (nextPay,bondDp))
  = (lastCollect, lastPay,head futurePayDates, pa, ba, end) 
    where 
      futurePayDates = genSerialDatesTill2 IE nextPay bondDp end 
      ba = [ RunWaterfall _d "" | _d <- futurePayDates]
      futureCollectDates = genSerialDatesTill2 IE nextCollect poolDp end 
      pa = [ PoolCollection _d "" | _d <- futureCollectDates]

calcDealStageDate :: DateDesp -> [(Date,DealStatus)]
calcDealStageDate (PreClosingDates _ closing Nothing endDate _ _) 
  = [(closing,Amortizing),(endDate,Ended)]
calcDealStageDate (PreClosingDates _ closing (Just revolvingEndDate) endDate _ _) 
  = [(closing,Revolving),(revolvingEndDate,Amortizing),(endDate,Ended)]
calcDealStageDate (CurrentDates _ Nothing endDate _ _) 
  = [(endDate,Ended)]
calcDealStageDate (CurrentDates _ (Just revolvingEndDate) endDate _ _) 
  = [(revolvingEndDate,Amortizing),(endDate,Ended)]
calcDealStageDate _ = []


runPool2 :: P.Asset a => (P.Pool a) -> Maybe AP.ApplyAssumptionType -> [CF.CashFlowFrame]
runPool2 (P.Pool [] (Just cf) asof _) Nothing = [cf]
runPool2 (P.Pool [] (Just cf) asof _) (Just (AP.PoolLevel [])) = [cf]
runPool2 (P.Pool [] (Just (CF.CashFlowFrame txn)) asof _) (Just (AP.PoolLevel assumps)) 
  = [ (P.projCashflow (ACM.ScheduleMortgageFlow asof txn) asof assumps) ] -- `debug` ("PROJ in schedule flow")
runPool2 (P.Pool as _ asof _) Nothing = map (\x -> P.calcCashflow x asof) as -- `debug` ("RUNPOOL-> calc cashflow")
runPool2 (P.Pool as Nothing asof _) (Just applyAssumpType)
  = case applyAssumpType of
       AP.PoolLevel [] -> map (\x -> P.calcCashflow x asof) as  -- `debug` ("In Run pool"++show as)
       AP.PoolLevel assumps -> map (\x -> P.projCashflow x asof assumps) as  -- `debug` (">> Single Pool")
       AP.ByIndex idxAssumps _ ->
         let
           numAssets = length as
           _assumps = map (AP.lookupAssumptionByIdx idxAssumps) [0..(pred numAssets)] -- `debug` ("Num assets"++ show numAssets)
         in
           zipWith (\x a -> P.projCashflow x asof a) as _assumps


getInits :: P.Asset a => TestDeal a -> Maybe AP.ApplyAssumptionType ->
    ([ActionOnDate], CF.CashFlowFrame, [RateAssumption],Maybe [C.CallOption])
getInits t mAssumps 
  = (allActionDates, pCollectionCfAfterCutoff, rateCurves, callOptions)  -- `debug` ("Assump"++ show mAssumps)
  where
    dealAssumps = case mAssumps of
                    Just (AP.PoolLevel []) -> []
                    Just (AP.PoolLevel _aps) -> fst $ AP.splitAssumptions _aps ([],[])
                    Just (AP.ByIndex _ _aps) -> _aps
                    Nothing -> []
    
    (startDate,closingDate,firstPayDate,pActionDates,bActionDates,endDate) = populateDealDates (dates t)
    dealStatusDates = calcDealStageDate (dates t) 
    dealStageDates = [ ChangeDealStatusTo d s | (d,s) <- dealStatusDates ]
    intEarnDates = A.buildEarnIntAction (Map.elems (accounts t)) endDate [] -- `debug` (show (startDate,firstPayDate,pActionDates,bActionDates,endDate))
    iAccIntDates = [ EarnAccInt _d accName | (accName,accIntDates) <- intEarnDates
                                           , _d <- accIntDates ] -- `debug` ("PoolactionDates"++show  pActionDates)
    --fee accrue dates 
    _feeAccrueDates = F.buildFeeAccrueAction (Map.elems (fees t)) endDate []
    feeAccrueDates = [ AccrueFee _d _feeName | (_feeName,feeAccureDates) <- _feeAccrueDates
                                           , _d <- feeAccureDates ]
    --liquidation facility
    liqResetDates = case liqProvider t of 
                      Nothing -> []
                      Just mLiqProvider -> 
                          let 
                            _liqResetDates = CE.buildLiqResetAction (Map.elems mLiqProvider) endDate []                    
                          in 
                            [ ResetLiqProvider _d _liqName |(_liqName,__liqResetDates) <- _liqResetDates
                                                          , _d <- __liqResetDates ]
    --inspect dates 
    inspectDates = let 
                     m_inspect_vars = find (\case
                                           (AP.InspectOn _ ) -> True
                                           _ -> False)
                                         dealAssumps 
                   in
                     case m_inspect_vars of 
                       Just (AP.InspectOn inspect_vars) ->
                           let 
                             _int = [[ InspectDS _d ds | _d <- genSerialDatesTill2 II startDate dp endDate]  | (dp,ds) <- inspect_vars ]
                           in 
                             foldr (++) [] _int
                       Nothing -> []  -- `debug` ("M inspect"++show dealAssumps)
                     
    stopDate = find 
                 (\case
                   (AP.StopRunBy d) -> True
                   _ -> False)
                 dealAssumps 
    
    _actionDates = let 
                     -- a = bActionDates ++ pActionDates ++ iAccIntDates ++ feeAccrueDates ++ liqResetDates ++ dealStageDates ++ inspectDates
                     a = foldr (++) [] [bActionDates,pActionDates,iAccIntDates
                                        ,feeAccrueDates,liqResetDates,dealStageDates,inspectDates] -- `debug` ("inspect Dates"++show inspectDates)
                   in
                     case dates t of 
                       (PreClosingDates _ _ _ _ _ _) -> sort $ (DealClosed closingDate):a 
                       _ -> sort a
                      
    allActionDates = case stopDate of
                       Just (AP.StopRunBy d) ->
                         filter (\x -> getDate x < d) _actionDates
                       Nothing ->  _actionDates   -- `debug` ("Action days") -- `debug` (">>action dates done"++show(_actionDates))

    poolCf = P.aggPool $ runPool2 (pool t) mAssumps  -- `debug` ("agg pool flow")
    poolCfTs = filter (\txn -> CF.getDate txn >= startDate)  $ CF.getTsCashFlowFrame poolCf -- `debug` ("Pool Cf in pool>>"++show poolCf)
    pCollectionCfAfterCutoff = CF.CashFlowFrame $ CF.aggTsByDates poolCfTs (getDates pActionDates)  -- `debug`  (("poolCf "++ show poolCfTs) )
    rateCurves = buildRateCurves [] dealAssumps  
    callOptions = buildCallOptions Nothing dealAssumps -- `debug` ("Assump"++show(assumps))

queryDealRate :: P.Asset a => TestDeal a -> DealStats -> Micro
queryDealRate t s =
  fromRational $ 
    case s of
      BondFactor ->
           toRational (queryDeal t CurrentBondBalance) / toRational (queryDeal t OriginalBondBalance)

      PoolFactor ->
           toRational (queryDeal t CurrentPoolBalance)  / toRational (queryDeal t OriginalPoolBalance)

      FutureCurrentPoolFactor asOfDay ->
           toRational (queryDeal t FutureCurrentPoolBalance) / toRational (queryDeal t OriginalPoolBalance)
      
      CumulativePoolDefaultedRate ->
          let 
            originPoolBal = toRational (queryDeal t OriginalPoolBalance) -- `debug` ("A")-- `debug` (">>Pool Bal"++show (queryDeal t OriginalPoolBalance))
            cumuPoolDefBal = toRational (queryDeal t CumulativePoolDefaultedBalance) -- `debug` ("B") -- `debug` (">>CUMU"++show (queryDeal t CumulativePoolDefaultedBalance))
          in 
            cumuPoolDefBal / originPoolBal -- `debug` ("cumulative p def rate"++show cumuPoolDefBal++">>"++show originPoolBal)

queryDealInt :: P.Asset a => TestDeal a -> DealStats -> Date -> Int 
queryDealInt t s d = 
  case s of 
    FutureCurrentPoolBorrowerNum d ->
      case P.futureCf (pool t) of 
        Nothing -> 0
        Just (CF.CashFlowFrame trs) -> 
            let 
              (_cf,_) = splitByDate trs d EqToLeft
            in 
              fromMaybe 0 $ CF.mflowBorrowerNum $ last _cf

    MonthsTillMaturity bn -> 
        case mm of 
          Nothing -> error "Should not happend"
          Just md -> fromInteger $ T.cdMonths $ T.diffGregorianDurationClip md d
        where
            (L.Bond _ _ (L.OriginalInfo _ _ _ mm) _ _ _ _ _ _ _ _ _) = (bonds t) Map.! bn  

queryDeal :: P.Asset a => TestDeal a -> DealStats -> Balance
queryDeal t s = 
  case s of
    CurrentBondBalance ->
       Map.foldr (\x acc -> L.bndBalance x + acc) 0.0 (bonds t)
    OriginalBondBalance ->
       Map.foldr (\x acc -> L.originBalance (L.bndOriginInfo x) + acc) 0.0 (bonds t)
    CurrentPoolBalance ->
       foldl (\acc x -> acc + P.getCurrentBal x) 0.0 (P.assets (pool t)) -- `debug` ("Qurey loan level asset balance")
    CurrentPoolDefaultedBalance ->
       foldl (\acc x -> acc + P.getCurrentBal x)
             0.0 $
             filter P.isDefaulted (P.assets (pool t))
    OriginalPoolBalance ->
       case P.issuanceStat (pool t) of
         Just m -> Map.findWithDefault (-1) P.IssuanceBalance m -- `debug` (">>>>"++show(m))
         Nothing -> foldl (\acc x -> acc + P.getOriginBal x) 0.0 (P.assets (pool t)) 
    CurrentPoolBorrowerNum ->
       fromRational $ toRational $ foldl (\acc x -> acc + P.getBorrowerNum x) 0 (P.assets (pool t)) -- `debug` ("Qurey loan level asset balance")
 
    AllAccBalance ->
        sum $ map A.accBalance $ Map.elems (accounts t) -- `debug` ("Summing acc balance")
    
    AccBalance ans -> 
        sum $ map A.accBalance $ Map.elems $ getAccountByName t (Just ans)

    ReserveAccGapAt d ans ->
        max 0 $
          (sum $ map 
                   (calcTargetAmount t d) $ 
                   Map.elems $ getAccountByName t (Just ans))
          - 
          (queryDeal t (AccBalance ans))  -- `debug` (">>"++show (sum $ map (calcTargetAmount t d) $ Map.elems $ getAccountByName t (Just ans)) ++">>>"++ show (queryDeal t (AccBalance ans)))

    FutureCurrentPoolBalance ->
       case P.futureCf (pool t) of 
         Nothing -> 0.0
         Just (CF.CashFlowFrame trs) -> CF.mflowBalance $ last trs

    FutureCurrentPoolBegBalance asOfDay ->
         case _poolSnapshot of
            Just ts -> CF.mflowBegBalance ts
            Nothing -> -0.1
        where
         _pool_cfs = fromMaybe (CF.CashFlowFrame []) (P.futureCf (pool t))
         _poolSnapshot = CF.getEarlierTsCashFlowFrame _pool_cfs asOfDay -- `debug` (">>CurrentPoolBal"++show(asOfDay)++">>Pool>>"++show(_pool_cfs))

    PoolCollectionHistory incomeType fromDay asOfDay ->
      sum fieldAmts
      where
        fieldAmts = map
                      (case incomeType of 
                        CollectedInterest -> CF.mflowInterest 
                        CollectedPrincipal -> CF.mflowPrincipal 
                        CollectedPrepayment -> CF.mflowPrepayment
                        CollectedRecoveries -> CF.mflowRecovery)    
                      subflow  -- `debug` ("SDED"++ show fromDay ++ show asOfDay ++"Pool Collection Histroy"++show subflow)
        subflow = case P.futureCf (pool t) of
                    Nothing ->  []
                    Just _futureCf -> 
                        if fromDay == asOfDay then 
                            CF.getTxnBetween2 _futureCf II fromDay asOfDay
                        else 
                            CF.getTxnBetween2 _futureCf EI fromDay asOfDay

    CumulativePoolDefaultedBalance ->
        let
          futureDefaults = case P.futureCf (pool t) of
                             Just (CF.CashFlowFrame _historyTxn) 
                                -> foldr 
                                     (\r a -> CF.tsDefaultBal r + a) 
                                     0 
                                     _historyTxn
                             Nothing -> 0.0  -- `debug` ("Geting future defaults"++show futureDefaults)
          currentDefaults = queryDeal t CurrentPoolDefaultedBalance
        in
          futureDefaults + currentDefaults

    CurrentBondBalanceOf bns ->
       let
          bSubMap = getBondByName t (Just bns) -- Map.filterWithKey (\bn b -> (S.member bn bnSet)) (bonds t)
       in
          sum $ map L.bndBalance $ Map.elems bSubMap

    BondsIntPaidAt d bns ->
       let
          bSubMap =  getBondByName t (Just bns)   -- Map.filterWithKey (\bn b -> S.member bn bnSet) (bonds t)
          stmts = map L.bndStmt $ Map.elems bSubMap
          ex s = case s of
                   Nothing -> 0
                   Just (Statement txns) 
                     -> sum $ map getTxnAmt $
                          filter (\y -> case getTxnComment y of 
                                          (PayInt _ _) -> True
                                          _ -> False)   $
                          filter (\x -> d == getDate x) txns
       in
          sum $ map ex stmts

    BondsPrinPaidAt d bns ->
       let
          bSubMap =  getBondByName t (Just bns)   -- Map.filterWithKey (\bn b -> S.member bn bnSet) (bonds t)
          stmts = map L.bndStmt $ Map.elems bSubMap
          ex s = case s of
                   Nothing -> 0
                   Just (Statement txns) 
                     -> sum $ map getTxnAmt $
                          filter (\y -> case getTxnComment y of 
                                          (PayPrin _ _) -> True
                                          _ -> False)   $
                          filter (\x -> d == getDate x) txns
       in
          sum $ map ex stmts

    BondBalanceGapAt d bName -> 
        let 
           bn@L.Bond{L.bndType = L.PAC _target} = (bonds t) Map.! bName
           bal = L.bndBalance bn
           targetBal = getValOnByDate _target d
        in 
           max 0 $ bal - targetBal  -- `debug` ("B T"++ show bal++"|"++show targetBal)

    FeesPaidAt d fns ->
       let
          -- fnSet = S.fromList fns
          -- fSubMap = Map.filterWithKey (\fn f -> (S.member fn fnSet)) (fees t)
          fSubMap = getFeeByName t (Just fns)
          stmts = map F.feeStmt $ Map.elems fSubMap
          ex s = case s of
                   Nothing -> 0
                   Just (Statement txns) -> sum $ map getTxnAmt $ filter (\x ->  d == getDate x) txns
       in
          sum $ map ex stmts

    CurrentDueBondInt bns ->
        let
           -- bnSet = S.fromList bns
           -- bSubMap = Map.filterWithKey (\bn b -> (S.member bn bnSet)) (bonds t)
           bSubMap =  getBondByName t (Just bns)   -- Map.filterWithKey (\bn b -> S.member bn bnSet) (bonds t)
        in
           sum $ map L.bndDueInt $ Map.elems bSubMap

    CurrentDueFee fns ->
        let
           -- fnSet = S.fromList fns
           -- fSubMap = Map.filterWithKey (\fn f -> (S.member fn fnSet)) (fees t)
           fSubMap = getFeeByName t (Just fns)
        in
           sum $ map F.feeDue $ Map.elems fSubMap

    Sum _s ->
        sum $ map (queryDeal t) _s

    Substract (ds:dss) -> 
        let 
          a  = queryDeal t ds 
          bs = queryDeal t (Sum dss) 
        in 
          a - bs  -- `debug` ("SS->"++show a ++"SS2->"++ show bs)

    Constant n -> fromRational n

    Max ds1 ds2 ->
        max (queryDeal t ds1) (queryDeal t ds2)
     
    Min ds1 ds2 ->
        min (queryDeal t ds1) (queryDeal t ds2) -- `debug` ("MIN->"++ show (queryDeal t ds1)++"|"++ show (queryDeal t ds2)++show ds2)

    Divide ds1 ds2 -> queryDeal t ds1 / queryDeal t ds2

    CustomData s d ->
        case custom t of 
          Nothing -> 0 
          Just mCustom ->
              case mCustom Map.! s of 
                CustomConstant v -> fromRational v 
                CustomCurve cv -> (getValOnByDate cv d)
                CustomDS ds -> (queryDeal t (patchDateToStats d ds ))

    _ -> 0.0 `debug` ("Failed to match"++ show s)

queryDealBool :: P.Asset a => TestDeal a -> DealStats -> Bool
queryDealBool t ds = False


getPoolFlows :: TestDeal a -> Maybe Date -> Maybe Date -> RangeType -> [CF.TsRow]
getPoolFlows t sd ed rt =
  case (sd,ed) of
    (Nothing,Nothing) ->  _trs
    (Nothing,Just _ed) -> case rt of 
                             EI -> filter (\x -> CF.getDate x <= _ed) _trs
    (Just _sd,Nothing) -> CF.getTxnAfter _projCf _sd   -- >= d
    (Just _sd,Just _ed) -> case rt of 
                             IE -> filter (\x -> (CF.getDate x >= _sd) && (CF.getDate x < _ed)) _trs
                             EI -> filter (\x -> (CF.getDate x > _sd) && (CF.getDate x <= _ed)) _trs
  where
    _projCf = fromMaybe (CF.CashFlowFrame []) (P.futureCf (pool t))
    _trs =  CF.getTsCashFlowFrame _projCf

--getBondStmts :: TestDeal -> [String] -> Maybe Date -> Maybe Date -> Map String [Txn]
--getBondStmts t bondNames startDate endDate
--  =
calcDayToPoolDate :: (TestDeal a) -> Date -> Date 
calcDayToPoolDate t calcDay 
  = CF.mflowDate $ last pFlows -- `debug` ("calDayToPoolDate"++show calcDay ++">>>>>"++show pFlows)
    where 
      pFlows = getPoolFlows t Nothing (Just calcDay) EI  -- II here is not being used

calcDueFee :: P.Asset a => (TestDeal a) -> Date -> F.Fee -> F.Fee
calcDueFee t calcDay f@(F.Fee fn (F.FixFee amt) fs fd fdDay fa _ _)
  | isJust fdDay = f  
  | calcDay >= fs && (isNothing fdDay) = f{ F.feeDue = amt, F.feeDueDate = Just calcDay} -- `debug` ("DEBUG--> init with amt "++show(fd)++show amt)
  | otherwise = f

calcDueFee t calcDay f@(F.Fee fn (F.AnnualRateFee feeBase r) fs fd Nothing fa lpd _)
  | calcDay >= fs = calcDueFee t calcDay f {F.feeDueDate = Just fs }
  | otherwise = f -- `debug` ("Fee Equal ? "++show calcDay ++show fs)

calcDueFee t calcDay f@(F.Fee fn (F.AnnualRateFee feeBase r) fs fd (Just _fdDay) fa lpd _)
  = f{ F.feeDue=fd+newDue, F.feeDueDate = Just newDueDay }  -- `debug` ("Fee DUE new Due "++show calcDay ++show baseBal ++show(newDue))                   
      where 
        accrueStart = _fdDay
        collectionEndDay = calcDayToPoolDate t calcDay
        (baseBal,newDueDay) = case feeBase of
                                CurrentPoolBalance ->  (CF.mflowWeightAverageBalance accrueStart calcDay $ getPoolFlows t Nothing Nothing II,collectionEndDay)-- `debug` ("FeeBase" ++ show (getPoolFlows t Nothing Nothing II))
                                -- CurrentPoolBegBalance ->  CF.mflowWeightAverageBalance accrueStart calcDay $ getPoolFlows t Nothing Nothing
                                OriginalPoolBalance -> (mulBR (P.getIssuanceField (pool t) P.IssuanceBalance) (yearCountFraction DC_ACT_365F accrueStart calcDay),collectionEndDay)
                                OriginalBondBalance -> (mulBR (queryDeal t OriginalBondBalance) (yearCountFraction DC_ACT_365F accrueStart calcDay),calcDay)
                                CurrentBondBalance -> (Map.foldr (\v a-> a + L.weightAverageBalance accrueStart calcDay v ) 0.0 (bonds t),calcDay)
                                CurrentBondBalanceOf bns -> (Map.foldr (\v a-> a + L.weightAverageBalance accrueStart calcDay v ) 0.0 (getBondByName t (Just bns)),calcDay)

        newDue = mulBR baseBal r

calcDueFee t calcDay f@(F.Fee fn (F.PctFee (PoolCollectionIncome it) r ) fs fd fdDay fa lpd _)
  = f { F.feeDue = newDueFee, F.feeDueDate = Just calcDay } -- `debug` ("BAL"++show baseBal++"New Fee Due"++ show newDueFee)
    where 
      baseBal = queryDeal t (PoolCollectionHistory it lastBegDay calcDay)  
                   -- `debug` ("PH query at "++ show calcDay ++ ">>>" ++ show it++">>"++show lastBegDay++">>"++show calcDay)
      newDueFee = fd + mulBR baseBal r
      lastBegDay = case fdDay of
                     (Just _fdDay) -> _fdDay
                     Nothing -> fs

calcDueFee t calcDay f@(F.Fee fn (F.PctFee ds r ) fs fd fdDay fa lpd _)
  = f { F.feeDue = fd + mulBR baseBal r, F.feeDueDate = Just calcDay }
    where 
      baseBal = queryDeal t (patchDateToStats calcDay ds)
      lastBegDay = case fdDay of
                     (Just _fdDay) -> _fdDay
                     Nothing -> fs

calcDueFee t calcDay f@(F.Fee fn (F.FeeFlow ts)  fs fd _ fa mflpd _)
  = f{ F.feeDue = newFeeDue
      ,F.feeDueDate = Just calcDay
      ,F.feeType = (F.FeeFlow futureDue)} -- `debug` ("New fee due"++show newFeeDue)
    where
      (currentNewDue,futureDue) = splitTsByDate ts calcDay
      cumulativeDue = sumValTs currentNewDue
      newFeeDue =  cumulativeDue + fd  -- `debug` ("cumulativeDue"++ show cumulativeDue)

calcDueFee t calcDay f@(F.Fee fn (F.RecurFee p amt)  fs fd Nothing fa _ _)
  = f{ F.feeDue = amt * (fromIntegral (periodGaps - 1)), F.feeDueDate = Just calcDay } -- `debug` ("New fee"++show(f))
  where
    periodGaps = length $ projDatesByPattern p fs calcDay  -- `debug` ("###"++show (projDatesByPattern p fs calcDay))

calcDueFee t calcDay f@(F.Fee fn (F.RecurFee p amt)  fs fd (Just _fdDay) fa _ _)
  | _fdDay == calcDay = f
  | periodGap == 0 = f
  | otherwise = f { F.feeDue = (fd+(amt*(fromIntegral (periodGap - 1)))) , F.feeDueDate = Just calcDay } -- `debug` ("Gap->"++show(fromIntegral periodGap))
  where
    periodGap =  length $ projDatesByPattern p _fdDay calcDay

calcDueFee t calcDay f@(F.Fee fn (F.NumFee p s amt) fs fd Nothing fa lpd _)
  | calcDay >= fs = calcDueFee t calcDay f {F.feeDueDate = Just fs }
  | otherwise = f 

calcDueFee t calcDay f@(F.Fee fn (F.NumFee p s amt) fs fd (Just _fdDay) fa lpd _)
  | _fdDay == calcDay = f 
  | periodGap == 0 = f 
  | otherwise = f { F.feeDue = fd+newFeeDueAmt , F.feeDueDate = Just calcDay } 
  where 
    dueDates = projDatesByPattern p _fdDay (pred calcDay)
    periodGap = length dueDates  -- `debug` ("Due Dates"++ show dueDates)
    baseCount = queryDealInt t (patchDateToStats calcDay s) calcDay
    newFeeDueAmt = fromRational $ mulBInt amt $ baseCount * periodGap -- `debug` ("amt"++show amt++">>"++show baseCount++">>"++show periodGap)


updateLiqProvider :: P.Asset a => TestDeal a -> Date -> CE.LiqFacility -> CE.LiqFacility
updateLiqProvider t d liq@(CE.LiqFacility _ liqType (Just curBal) curCredit _ mRate stmt) -- refresh available balance
  = liq { CE.liqBalance = newBalance}
    where 
      newBalance = case liqType of 
                     CE.ReplenishSupport _ b -> Just (max b curBal)
                     CE.ByPct _ ds pct -> Just $ mulBR (queryDeal t (patchDateToStats d ds)) pct
                     _ -> Just curBal

updateLiqProvider _ _ liq = liq

accrueLiqProvider :: P.Asset a => TestDeal a -> Date -> CE.LiqFacility -> CE.LiqFacility
accrueLiqProvider t d liq@(CE.LiqFacility _ _ mCurBal curCredit sd mRate Nothing)
  = accrueLiqProvider t d $ liq{CE.liqStmt = Just defaultStmt} 
   where 
       defaultStmt = Statement [SupportTxn sd mCurBal 0 curCredit Empty]

accrueLiqProvider t d liq@(CE.LiqFacility _ _ mCurBal curCredit _ mRate stmt)
  = liq { CE.liqCredit = newBal
         ,CE.liqStmt = Just newStmt
         ,CE.liqRate = newRate} -- `debug` ("Accure liq"++ show liq)
    where 
      accureInt = case mRate of 
                    Nothing -> 0
                    Just (CE.FixRate _ r lastAccDate) -> 
                        let 
                          txns = getTxns stmt
                          bals = weightAvgBalanceByDates [lastAccDate,d] txns
                        in 
                          sum $ ((flip mulBR) r) <$> bals
      newBal = curCredit + accureInt
      newStmt = appendStmt stmt $ SupportTxn d mCurBal accureInt newBal Empty
      newRate = case mRate of 
                  Nothing -> Nothing
                  Just (CE.FixRate _x _y _z) -> Just $ CE.FixRate _x _y d


calcDueInt :: P.Asset a => TestDeal a -> Date -> L.Bond -> L.Bond
calcDueInt t calc_date b@(L.Bond _ _ oi io _ r dp di Nothing _ lastPrinPay _ ) 
  = calcDueInt t calc_date (b {L.bndDueIntDate = Just (getClosingDate (dates t))})

calcDueInt t calc_date b@(L.Bond bn L.Z bo bi bond_bal bond_rate _ _ _ lstIntPay _ _) 
  = b {L.bndDueInt = 0 }

calcDueInt t calc_date b@(L.Bond bn L.Equity bo (L.InterestByYield y) bond_bal _ _ int_due _ lstIntPay _ mStmt)
  = b {L.bndDueInt = newDue }  -- `debug` ("Yield Due Int >>"++ show bn++">> new due"++ show newDue++">> old due"++ show int_due )
  where
  newDue = L.backoutDueIntByYield calc_date b

calcDueInt t calc_date b@(L.Bond bn bt bo bi bond_bal bond_rate _ int_due (Just int_due_date) lstIntPay _ _ ) 
  | calc_date == int_due_date = b
  | otherwise = b {L.bndDueInt = (new_due_int+int_due),L.bndDueIntDate = Just calc_date }  --  `debug` ("Due INT"++show calc_date ++">>"++show(bn)++">>"++show int_due++">>"++show(new_due_int))
              where
                lastIntPayDay = case lstIntPay of
                                  Just pd -> pd
                                  Nothing -> getClosingDate (dates t)
                dc = case bi of 
                       L.Floater _ _ _ _dc _ _ -> _dc 
                       L.Fix _ _dc -> _dc 
                     
                new_due_int = calcInt (bond_bal+int_due) lastIntPayDay calc_date bond_rate DC_ACT_365F -- `debug` ("Bond bal"++show bond_bal++">>"++show lastIntPayDay++">>"++ show calc_date++">>"++show bond_rate)


calcDuePrin :: P.Asset a => (TestDeal a) -> T.Day -> L.Bond -> L.Bond
calcDuePrin t calc_date b@(L.Bond bn L.Sequential bo bi bond_bal _ prin_arr int_arrears _ _ _ _) =
  b {L.bndDuePrin = duePrin} 
  where
    duePrin = bond_bal 

calcDuePrin t calc_date b@(L.Bond bn (L.Lockout cd) bo bi bond_bal _ prin_arr int_arrears _ _ _ _) =
  if cd > calc_date then 
    b {L.bndDuePrin = 0}
  else
    b {L.bndDuePrin = duePrin}
  where
    duePrin = bond_bal 

calcDuePrin t calc_date b@(L.Bond bn (L.PAC schedule) bo bi bond_bal _ prin_arr int_arrears _ _ _ _) =
  b {L.bndDuePrin = duePrin} -- `debug` ("bn >> "++bn++"Due Prin set=>"++show(duePrin) )
  where
    scheduleDue = getValOnByDate schedule calc_date  
    duePrin = max (bond_bal - scheduleDue) 0 -- `debug` ("In PAC ,target balance"++show(schedule)++show(calc_date)++show(scheduleDue))

calcDuePrin t calc_date b@(L.Bond bn (L.PAC_Anchor schedule bns) bo bi bond_bal _ prin_arr int_arrears _ _ _ _) =
  b {L.bndDuePrin = duePrin} -- `debug` ("bn >> "++bn++"Due Prin set=>"++show(duePrin) )
  where
    scheduleDue = getValOnByDate schedule calc_date
    anchor_bond_balance = (queryDeal t (CurrentBondBalanceOf bns))
    duePrin = if (anchor_bond_balance > 0) then
                 max (bond_bal - scheduleDue) 0
              else
                 bond_bal

calcDuePrin t calc_date b@(L.Bond bn L.Z bo bi bond_bal bond_rate prin_arr int_arrears _ lstIntPay _ _) =
  if (all (\x -> (isZbond x)) activeBnds) then
      b {L.bndDuePrin = bond_bal} -- `debug` ("bn >> "++bn++"Due Prin set=>"++show(duePrin) )
  else 
      b {L.bndDuePrin = 0, L.bndBalance = new_bal, L.bndLastIntPay=Just calc_date} -- `debug` ("bn >> "++bn++"Due Prin set=>"++show(duePrin) )
  where
    isZbond (L.Bond _ L.Z _ _ _ _ _ _ _ _ _ _) = True
    isZbond (L.Bond _ _ _ _ _ _ _ _ _ _ _ _) = False
    
    activeBnds = filter (\x -> (L.bndBalance x) > 0) (Map.elems (bonds t))
    new_bal = bond_bal + dueInt
    lastIntPayDay = case lstIntPay of
                      Just pd -> pd
                      Nothing -> getClosingDate (dates t)
    dueInt = calcInt bond_bal lastIntPayDay calc_date bond_rate DC_ACT_365F

calcDuePrin t calc_date b@(L.Bond bn L.Equity bo bi bond_bal _ prin_arr int_arrears _ _ _ _) =
  b {L.bndDuePrin = bond_bal }

patchDateToStats :: Date -> DealStats -> DealStats
patchDateToStats d t
   = case t of
         CurrentPoolBalance -> FutureCurrentPoolBalance
         LastBondIntPaid bns -> BondsIntPaidAt d bns
         LastFeePaid fns -> FeesPaidAt d fns
         LastBondPrinPaid bns -> BondsPrinPaidAt d bns
         BondBalanceGap bn -> BondBalanceGapAt d bn
         Sum _ds -> Sum $ map (patchDateToStats d) _ds
         Substract _ds -> Substract $ map (patchDateToStats d) _ds
         Min d1 d2 -> Min (patchDateToStats d d1) (patchDateToStats d d2)
         Max d1 d2 -> Max (patchDateToStats d d1) (patchDateToStats d d2)
         Factor _ds r -> Factor (patchDateToStats d _ds) r
         UseCustomData n -> CustomData n d
         CurrentPoolBorrowerNum -> FutureCurrentPoolBorrowerNum d
         _ -> t

calcTargetAmount :: P.Asset a => TestDeal a -> Date -> A.Account -> Balance
calcTargetAmount t d (A.Account _ n i Nothing _ ) = 0
calcTargetAmount t d (A.Account _ n i (Just r) _ ) =
   eval r -- `debug` ("$$$$ Evaluating" ++show(r)++" result:==>>"++show((eval r)))
   where
     eval ra = case ra of
       A.PctReserve (Sum ds) _rate -> mulBR (queryDeal t (Sum (map (patchDateToStats d) ds))) _rate  -- `debug` ("In multiple query spot"++show(ds))
       A.PctReserve ds _rate -> mulBR (queryDeal t (patchDateToStats d ds))  _rate
       A.FixReserve amt -> amt
       A.Either p ra1 ra2 -> if testPre d t p then 
                                eval ra1
                            else 
                                eval ra2 
       A.Max ra1 ra2 -> max (eval ra1) (eval ra2)  -- `debug` ("Max result here ->>> left "++show(eval ra1)++" right "++show(eval ra2))
       A.Min ra1 ra2 -> min (eval ra1) (eval ra2)

depositPoolInflow :: [W.CollectionRule] -> T.Day -> CF.CashFlowFrame -> Map.Map String A.Account -> Map.Map String A.Account
depositPoolInflow rules d (CF.CashFlowFrame []) amap = amap -- `debug` ("Deposit inflow Nothing")
depositPoolInflow rules d (CF.CashFlowFrame txn) amap =
  foldl fn amap rules  -- `debug` ("Deposit inflow  at "++show(d)++"txn"++show(txn))
  where
      currentPoolInflow = txn

      fn _acc _r@(W.Collect _poolSource _accName) =
          Map.adjust (A.deposit collectedCash d (PoolInflow _poolSource)) _accName _acc
          where
              collectedCash = sum $ map (collectCash _r) currentPoolInflow

      collectCash r ts =
        case r of
          (W.Collect W.CollectedInterest _)   -> CF.mflowInterest ts
          (W.Collect W.CollectedPrincipal _)  -> CF.mflowPrincipal ts
          (W.Collect W.CollectedRecoveries _) -> CF.mflowRecovery ts
          (W.Collect W.CollectedPrepayment _) -> CF.mflowPrepayment ts
          (W.Collect W.CollectedRental _) -> CF.mflowRental ts

$(deriveJSON defaultOptions ''ExpectReturn)
$(deriveJSON defaultOptions ''TestDeal)


td = TestDeal {
  name = "test deal1"
  ,dates = PatternInterval $
             Map.fromList [(ClosingDate ,(T.fromGregorian 2022 1 1,MonthFirst,toDate("20300101")))
                         ,(CutoffDate,(T.fromGregorian 2022 1 1,MonthFirst,toDate("20300101")))
                         ,(FirstPayDate,(T.fromGregorian 2022 2 25,DayOfMonth 25,toDate("20300101") ))
                          ]
  ,status = Amortizing
  ,accounts = (Map.fromList
  [("General", (A.Account { A.accName="General" ,A.accBalance=0.0 ,A.accType=Nothing, A.accInterest=Nothing ,A.accStmt=Nothing
  })),
   ("Reserve", (A.Account { A.accName="General" ,A.accBalance=0.0 ,A.accType=Just (A.FixReserve 500), A.accInterest=Nothing ,A.accStmt=Nothing
  }))
   ,("ReservePCT", (A.Account { A.accName="General" ,A.accBalance=0.0
   ,A.accType=Just (A.PctReserve (FutureCurrentPoolBalance) 500)
   , A.accInterest=Nothing ,A.accStmt=Nothing
  }))
  ])
  ,fees = (Map.fromList [("Service-Fee"
                         ,F.Fee{F.feeName="service-fee"
                                ,F.feeType = F.FixFee 50
                                ,F.feeStart = (T.fromGregorian 2022 1 1)
                                ,F.feeDue = 100
                                ,F.feeDueDate = Nothing
                                ,F.feeArrears = 0
                                ,F.feeLastPaidDay = Nothing
                                ,F.feeStmt = Nothing})])
  ,bonds = (Map.fromList [("A"
                          ,L.Bond{
                              L.bndName="A"
                             ,L.bndType=L.Sequential
                             ,L.bndOriginInfo= L.OriginalInfo{
                                                L.originBalance=3000
                                                ,L.originDate= (T.fromGregorian 2022 1 1)
                                                ,L.originRate= 0.08
                                                ,L.maturityDate=Nothing}
                             ,L.bndInterestInfo= L.Fix 0.08 DC_ACT_365F
                             ,L.bndBalance=3000
                             ,L.bndRate=0.08
                             ,L.bndDuePrin=0.0
                             ,L.bndDueInt=0.0
                             ,L.bndDueIntDate=Nothing
                             ,L.bndLastIntPay = Just (T.fromGregorian 2022 1 1)
                             ,L.bndLastPrinPay = Just (T.fromGregorian 2022 1 1)
                             ,L.bndStmt=Nothing})
                         ]
           )
  ,pool = P.Pool {P.assets=[ACM.Mortgage
                                         P.MortgageOriginalInfo{
                                           P.originBalance=4000
                                           ,P.originRate=P.Fix 0.085
                                           ,P.originTerm=60
                                           ,P.period=Monthly
                                           ,P.startDate=(T.fromGregorian 2022 1 1)
                                           ,P.prinType= P.Level}
                                         4000
                                         0.085
                                         60
                                         Nothing
                                         P.Current
                                         ]
                 ,P.futureCf=Nothing
                 ,P.asOfDate=T.fromGregorian 2022 1 1
                 ,P.issuanceStat= Just (Map.fromList [(P.IssuanceBalance,4000)])
                 }
   ,waterfall = Map.fromList [(W.DistributionDay Amortizing, [
                                 (Nothing, W.PayFee ["General"] ["Service-Fee"])
                                 ,(Nothing, W.PayFeeBy (W.DuePct 0.5) ["General"] ["Service-Fee"])
                                 ,(Nothing, W.TransferReserve W.Source  "General" "General")
                                 ,(Nothing, W.TransferReserve W.Target  "General" "General")
                                 ,(Nothing, W.PayInt "General" ["A"])
                                 ,(Nothing, W.PayPrin "General" ["A"])])
                               ,(W.CleanUp, [(Nothing, W.LiquidatePool (BalanceFactor 1.0 0.2) "A")])]
 ,collects = [W.Collect W.CollectedInterest "General"
             ,W.Collect W.CollectedPrincipal "General"]
 ,call = Just [C.PoolFactor 0.08]
 ,liqProvider = Nothing
 ,custom = Nothing
 ,triggers = Just $ 
               Map.fromList $
                 [(BeginDistributionWF,[(AfterDate (toDate "20220301"),DealStatusTo Revolving)])
                  ,(EndCollection,[(Always True,DoAccrueFee ["Service-Fee"])])
                  ,(EndDistributionWF, [(PassMaturityDate "A"
                                        ,DealStatusTo (DealAccelerated Nothing))])]
                   
 ,overrides = Just [ CustomActionOnDates 
                      [RunWaterfall (toDate "20220101") "base"
                      ,PoolCollection (toDate "20221101") "collection"] ]  
}
