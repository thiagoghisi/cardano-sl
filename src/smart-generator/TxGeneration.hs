module TxGeneration
       ( BambooPool
       , initTransaction
       , createBambooPool
       , curBambooTx
       , peekTx
       , nextValidTx
       , resetBamboo
       ) where

import           Control.Concurrent.STM.TArray (TArray)
import           Control.Concurrent.STM.TVar   (TVar, modifyTVar', newTVar, readTVar,
                                                writeTVar)
import           Control.TimeWarp.Timed        (sec)
import           Data.Array.MArray             (newListArray, readArray, writeArray)
import           Data.List                     (tail, (!!))
import           Universum                     hiding (head)

import           Pos.Constants                 (k, slotDuration)
import           Pos.Crypto                    (SecretKey, hash, toPublic, unsafeHash)
import           Pos.Genesis                   (genesisAddresses, genesisSecretKeys)
import           Pos.State                     (isTxVerified)
import           Pos.Types                     (Tx (..), TxId, makePubKeyAddress)
import           Pos.Wallet                    (makePubKeyTx)
import           Pos.WorkMode                  (WorkMode)

import           GenOptions                    (GenOptions (..))

-- txChain :: Int -> [Tx]
-- txChain i = genChain (genesisSecretKeys !! i) addr (unsafeHash addr) 0
--   where addr = genesisAddresses !! i

tpsTxBound :: Double -> Int -> Int
tpsTxBound tps propThreshold =
    round $ tps * fromIntegral (k + propThreshold) * fromIntegral (slotDuration `div` sec 1)

genChain :: SecretKey -> TxId -> Word32 -> [Tx]
genChain sk txInHash txInIndex =
    let addr = makePubKeyAddress $ toPublic sk
        tx = makePubKeyTx sk [(txInHash, txInIndex)] [(addr, 1)]
    in tx : genChain sk (hash tx) 0

initTransaction :: GenOptions -> Int -> Tx
initTransaction GenOptions {..} i =
    let maxTps = goInitTps + goTpsIncreaseStep * fromIntegral goRoundNumber
        n' = tpsTxBound (maxTps / fromIntegral (length goGenesisIdxs)) goPropThreshold
        n = min n' goInitBalance
        addr = genesisAddresses !! i
        sk = genesisSecretKeys !! i
        input = (unsafeHash addr, 0)
        outputs = replicate n (addr, 1)
    in makePubKeyTx sk [input] outputs

data BambooPool = BambooPool
    { bpChains :: TArray Int [Tx]
    , bpCurIdx :: TVar Int
    }

createBambooPool :: SecretKey -> Tx -> IO BambooPool
createBambooPool sk tx = atomically $ BambooPool <$> newListArray (0, outputsN - 1) bamboos <*> newTVar 0
    where outputsN = length $ txOutputs tx
          bamboos = map (tx :) $
                    map (genChain sk (hash tx) . fromIntegral) [0 .. outputsN - 1]

shiftTx :: BambooPool -> IO ()
shiftTx BambooPool {..} = atomically $ do
    idx <- readTVar bpCurIdx
    chain <- readArray bpChains idx
    writeArray bpChains idx $ tail chain

nextBamboo :: BambooPool -> Double -> Int -> IO ()
nextBamboo BambooPool {..} curTps propThreshold = atomically $ do
    let bound = tpsTxBound curTps propThreshold
    modifyTVar' bpCurIdx $ \idx ->
        (idx + 1) `mod` bound

resetBamboo :: BambooPool -> IO ()
resetBamboo BambooPool {..} = atomically $ writeTVar bpCurIdx 0

getTx :: BambooPool -> Int -> Int -> STM Tx
getTx BambooPool {..} bambooIdx txIdx =
    (!! txIdx) <$> readArray bpChains bambooIdx

curBambooTx :: BambooPool -> Int -> IO Tx
curBambooTx bp@BambooPool {..} idx = atomically $
    join $ getTx bp <$> readTVar bpCurIdx <*> pure idx

peekTx :: BambooPool -> IO Tx
peekTx bp = curBambooTx bp 0

nextValidTx :: WorkMode ssc m => BambooPool -> Double -> Int -> m (Either Tx Tx)
nextValidTx bp curTps propThreshold = do
    curTx <- liftIO $ curBambooTx bp 1
    isVer <- isTxVerified curTx
    liftIO $ if isVer
        then do
        shiftTx bp
        nextBamboo bp curTps propThreshold
        return $ Right curTx
        else do
        parentTx <- peekTx bp
        nextBamboo bp curTps propThreshold
        return $ Left parentTx
