{-# LANGUAGE OverloadedStrings, PackageImports, LambdaCase #-}

import Data.List
import Control.Applicative
import Control.Monad
import Control.Monad.Trans

--import Text.Trifecta (Result (..))

import System.Environment
import System.Directory
import System.FilePath
import System.IO
import Control.Exception
--import Prelude
import Text.Show.Pretty

import Type
import Typecheck
import Core
import Parser
import Driver
import CoreToIR

acceptPath = "./tests/accept"
rejectPath = "./tests/reject"
errorFileName lc = rejectPath </> (lc ++ ".error")
okFileName lc = acceptPath </> (lc ++ ".res")

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stdin NoBuffering
  args <- getArgs

  let (verboseFlags,samplesToAccept) = partition (== "-v") args
      verbose = verboseFlags /= []
  (testToAccept,testToReject) <- case samplesToAccept of
    [] -> do
      toAccept <- filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents acceptPath
      toReject <- filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents rejectPath
      return (map dropExtension toAccept,map dropExtension toReject)
    _ -> return (samplesToAccept,[])

  putStrLn $ "Checking valid pipelines"
  acceptTests testToAccept

  putStrLn $ "Catching errors (must get an error)"
  rejectTests testToReject

writeReduced = testFrame ["./tests/accept"] $ \case
    Left e -> Left e
    Right (Left e) -> Right ("typechecked", ppShow e)
    Right (Right e) -> Right ("reduced main ", ppShow . mkReduce . toCore mempty $ e)

main' x = acceptTests [x]

acceptTests = testFrame ["./tests/accept", "./tests/reject"] $ \case
    Left e -> Left e
    Right (Left e) -> Right ("typechecked", ppShow e)
    Right (Right e)
        | typingToTy (snd $ getTag e) == TCon0 "Output"
            -> Right ("compiled main", ppShow . compilePipeline . mkReduce . toCore mempty $ e)
        | typingToTy (snd $ getTag e) == TCon0 "Bool" -> case mkReduce . toCore mempty $ e of
            x@(A0t "True" (TCon0 "Bool")) -> Right ("main ~~> True", ppShow x)
            x -> Left $ "main should be True but it is \n" ++ ppShow x
        | otherwise -> Right ("reduced main ", ppShow . mkReduce . toCore mempty $ e)

rejectTests = testFrame ["./tests/reject", "./tests/accept"] $ \case
    Left e -> Right ("error message", e)
    _ -> Left "failed to catch error"

testFrame dirs f tests = fmap (either (error "impossible") id) $ runMM dirs $ forM_ (zip [1..] (tests :: [String])) $ \(i, n) -> do
    liftIO $ putStr $ " # " ++ pad 4 (show i) ++ pad 15 n ++ " ... "
    result <- catchMM $ getDef_ n "main"
    case f result of
      Left e -> liftIO $ putStrLn $ "\n!FAIL\n" ++ e
      Right (op, x) -> liftIO $ catch (length x `seq` compareResult (pad 15 op) (head dirs </> (n ++ ".out")) x) getErr
  where
    getErr :: ErrorCall -> IO ()
    getErr e = putStrLn $ "\n!FAIL\n" ++ limit "\n..." 4000 (show e)

compareResult msg ef e = doesFileExist ef >>= \b -> case b of
    False -> writeFile ef e >> putStrLn ("OK - " ++ msg ++ " is written")
    True -> do
        e' <- readFile ef
        case map fst $ filter snd $ zip [0..] $ zipWith (/=) e e' of
          [] -> putStrLn $ "OK - " ++ msg ++ " agrees"
          rs -> do
            putStrLn $ msg ++ " has changed."
            putStrLn "------------------------------------------- Old"
            putStrLn $ showRanges ef rs e'
            putStrLn "------------------------------------------- New"
            putStrLn $ showRanges ef rs e
            putStrLn "-------------------------------------------"
            putStr $ "Accept new " ++ msg ++ " (y/n)? "
            c <- length e' `seq` getChar
            if c `elem` ("yY\n" :: String)
                then writeFile ef e >> putStrLn " - accepted."
                else putStrLn " - not Accepted."

pad n s = s ++ replicate (n - length s) ' '

limit :: String -> Int -> String -> String
limit msg n s = take n s ++ if null (drop n s) then "" else msg

showRanges :: String -> [Int] -> String -> String
showRanges fname is e = (if head rs == 0 then "" else "...\n")
    ++ limit ("\n... (see " ++ fname ++ " for more differences)") 4000 (intercalate "\n...\n" $ f (zipWith (-) rs (0:rs)) e)
  where
    f :: [Int] -> String -> [String]
    f (i:is) e = g is $ drop i e
    f [] "" = []
    f [] _ = ["\n..."]
    g (i:is) e = take i e: f is (drop i e)
    rs = (head is - x) : concat [[a + x, b - x] | (a, b) <- zip is (tail is), a + y < b] ++ [last is + x]
    x = 200
    y = 3*x

