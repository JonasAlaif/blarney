{-|
Module      : Blarney.Verilog
Description : Verilog generation
Copyright   : (c) Matthew Naylor, 2019
License     : MIT
Maintainer  : mattfn@gmail.com
Stability   : experimental

Convert Blarney functions to Verilog modules.
-}

module Blarney.Verilog
  ( writeVerilogModule  -- Generate Verilog module
  , writeVerilogTop     -- Generate Verilog top-level module
  ) where

-- Standard imports
import Prelude hiding ((<>))
import qualified Data.Set as Set
import Data.Bits
import Data.List
import System.IO
import Data.Maybe
import System.Process
import Text.PrettyPrint
import Numeric (showHex)
import Data.Array.IArray

-- Blarney imports
import Blarney.BV
import Blarney.Net
import Blarney.Module
import Blarney.Interface
import Blarney.IfThenElse

-- Toplevel API
--------------------------------------------------------------------------------

-- | Convert given Blarney function to a Verilog module
writeVerilogModule :: Modular a
                   => a          -- ^ Blarney function
                   -> String     -- ^ Module name
                   -> String     -- ^ Output directory
                   -> IO ()
writeVerilogModule top mod dir =
    do system ("mkdir -p " ++ dir)
       nl <- netlist (makeModule top)
       writeVerilog fileName mod nl
  where
    fileName = dir ++ "/" ++ mod ++ ".v"

-- | Convert given Blarney function to a top-level Verilog module
writeVerilogTop :: Module ()  -- ^ Blarney module
                -> String     -- ^ Top-level module name
                -> String     -- ^ Output directory
                -> IO ()
writeVerilogTop top mod dir =
    do nl <- netlist top
       system ("mkdir -p " ++ dir)
       writeVerilog (dir ++ "/" ++ mod ++ ".v") mod nl
       writeFile (dir ++ "/" ++ mod ++ ".cpp") simCode
       writeFile (dir ++ "/" ++ mod ++ ".mk") makefileIncCode
       writeFile (dir ++ "/Makefile") makefileCode
  where
    fileName = dir ++ "/" ++ mod ++ ".v"

    simCode =
      unlines [
        "// Generated by Blarney"
      , "#include <verilated.h>"
      , "#include \"V" ++ mod ++ ".h\""
      , "V" ++ mod ++ " *top;"
      , "vluint64_t main_time = 0;"
      , "// Called by $time in Verilog"
      , "double sc_time_stamp () {"
      , "  return main_time;"
      , "}"
      , "int main(int argc, char** argv) {"
      , "  Verilated::commandArgs(argc, argv);"
      , "  top = new V" ++ mod ++ ";"
      , "  while (!Verilated::gotFinish()) {"
      , "    top->clock = 0; top->eval();"
      , "    top->clock = 1; top->eval();"
      , "    main_time++;"
      , "  }"
      , "  top->final(); delete top; return 0;"
      , "}"
      ]

    makefileIncCode =
      unlines [
        "all: " ++ mod
      , mod ++ ": *.v *.cpp"
      , "\tverilator -cc " ++ mod ++ ".v " ++ "-exe "
                           ++ mod ++ ".cpp " ++ "-o " ++ mod
                           ++ " -Wno-UNSIGNED"
                           ++ " -y $(BLARNEY_ROOT)/Verilog"
                           ++ " --x-assign unique"
                           ++ " --x-initial unique"
      , "\tmake -C obj_dir -j -f V" ++ mod ++ ".mk " ++ mod
      , "\tcp obj_dir/" ++ mod ++ " ."
      , "\trm -rf obj_dir"
      , ".PHONY: clean clean-" ++ mod
      , "clean: clean-" ++ mod
      , "clean-" ++ mod ++ ":"
      , "\trm -f " ++ mod
      ]

    makefileCode = "include *.mk"

writeVerilog :: String -> String -> Netlist -> IO ()
writeVerilog fileName modName netlist = do
  h <- openFile fileName WriteMode
  hPutStr h (render $ showVerilogModule modName netlist)
  hClose h

-- Internal helpers
--------------------------------------------------------------------------------

-- NetVerilog helper type
data NetVerilog = NetVerilog { decl :: Maybe Doc -- declaration
                             , inst :: Maybe Doc -- instanciation
                             , alws :: Maybe Doc -- always block
                             , rst  :: Maybe Doc -- reset logic
                             }
-- pretty helpers
--------------------------------------------------------------------------------
dot = char '.'
spaces n = hcat $ replicate n space
hexInt n = text (showHex n "")
argStyle as = sep $ punctuate comma as

showVerilogModule :: String -> Netlist -> Doc
showVerilogModule modName netlst =
      hang (hang (text "module" <+> text modName) 2 (parens (showIOs)) <> semi)
        2 moduleBody
  $+$ text "endmodule"
  where moduleBody =
              showComment "Declarations" $+$ showCommentLine
          $+$ sep (catMaybes $ map decl netVs)
          $+$ showComment "Instances" $+$ showCommentLine
          $+$ sep (catMaybes $ map inst netVs)
          $+$ showComment "Always block" $+$ showCommentLine
          $+$ hang (text "always"
                    <+> char '@' <> parens (text "posedge clock")
                    <+> text "begin") 2 alwaysBody
          $+$ text "end"
        alwaysBody =
              hang (text "if (reset) begin") 2 (sep (catMaybes $ map rst netVs))
          $+$ hang (text "end else begin") 2 (sep (catMaybes $ map alws netVs))
          $+$ text "end"
        nets = catMaybes $ elems netlst
        netVs = map (genNetVerilog netlst) nets
        netPrims = map netPrim nets
        ins = [Input w s | (w, s) <- nub [(w, s) | Input w s <- netPrims]]
        outs = [Output w s | Output w s <- netPrims]
        showIOs = argStyle $ text "input wire clock"
                           : text "input wire reset"
                           : map showIO (ins ++ outs)
        showIO (Input w s) =     text "input wire"
                             <+> brackets (int (w-1) <> text ":0")
                             <+> text s
        showIO (Output w s) = text "output wire"
                              <+> brackets (int (w-1) <> text ":0")
                              <+> text s
        showIO _ = text ""
        showComment cmt = text "//" <+> text cmt
        --showCommentLine = remainCols (\r -> p "//" <> p (replicate (r-2) '/'))
        showCommentLine = text (replicate 78 '/')

-- generate NetVerilog
--------------------------------------------------------------------------------
genNetVerilog :: Netlist -> Net -> NetVerilog
genNetVerilog netlist net = case netPrim net of
  Add w                   -> primNV { decl = Just $ declWire w wId }
  Sub w                   -> primNV { decl = Just $ declWire w wId }
  Mul w                   -> primNV { decl = Just $ declWire w wId }
  Div w                   -> primNV { decl = Just $ declWire w wId }
  Mod w                   -> primNV { decl = Just $ declWire w wId }
  Not w                   -> primNV { decl = Just $ declWire w wId }
  And w                   -> primNV { decl = Just $ declWire w wId }
  Or w                    -> primNV { decl = Just $ declWire w wId }
  Xor w                   -> primNV { decl = Just $ declWire w wId }
  ShiftLeft w             -> primNV { decl = Just $ declWire w wId }
  ShiftRight w            -> primNV { decl = Just $ declWire w wId }
  ArithShiftRight w       -> primNV { decl = Just $ declWire w wId }
  Equal w                 -> primNV { decl = Just $ declWire 1 wId }
  NotEqual w              -> primNV { decl = Just $ declWire 1 wId }
  LessThan w              -> primNV { decl = Just $ declWire 1 wId }
  LessThanEq w            -> primNV { decl = Just $ declWire 1 wId }
  ReplicateBit w          -> primNV { decl = Just $ declWire w wId }
  ZeroExtend wi wo        -> primNV { decl = Just $ declWire wo wId }
  SignExtend wi wo        -> primNV { decl = Just $ declWire wo wId }
  SelectBits w hi lo      -> primNV { decl = Just $ declWire (1+hi-lo) wId }
  Concat aw bw            -> primNV { decl = Just $ declWire (aw+bw) wId }
  Mux w                   -> primNV { decl = Just $ declWire w wId }
  CountOnes w             -> primNV { decl = Just $ declWire w wId }
  Identity w              -> primNV { decl = Just $ declWire w wId }
  Const w i               -> dfltNV { decl = Just $ declWireInit w wId i }
  DontCare w              -> dfltNV { decl = Just $ declWireDontCare w wId }
  Register i w            -> dfltNV { decl = Just $ declRegInit w wId i
                                    , alws = Just $ alwsRegister net
                                    , rst  = Just $ resetRegister w wId i }
  RegisterEn i w          -> dfltNV { decl = Just $ declRegInit w wId i
                                    , alws = Just $ alwsRegisterEn net
                                    , rst  = Just $ resetRegister w wId i }
  BRAM i aw dw            -> dfltNV { decl = Just $ declRAM i 1 aw dw net
                                    , inst = Just $ instRAM net i aw dw }
  TrueDualBRAM i aw dw    -> dfltNV { decl = Just $ declRAM i 2 aw dw net
                                    , inst = Just $ instTrueDualRAM net i aw dw }
  Display args            -> dfltNV { alws = Just $ alwsDisplay args net }
  Finish                  -> dfltNV { alws = Just $ alwsFinish net }
  TestPlusArgs s          -> dfltNV { decl = Just $ declWire 1 wId
                                    , inst = Just $ instTestPlusArgs wId s }
  Input w s               -> dfltNV { decl = Just $ declWire w wId
                                    , inst = Just $ instInput net s }
  Output w s              -> dfltNV { inst = Just $ instOutput net s }
  RegFileMake f aw dw vId -> dfltNV { decl = Just $ declRegFile f aw dw vId }
  RegFileRead w vId       -> dfltNV { decl = Just $ declWire w wId
                                    , inst = Just $ instRegFileRead vId net }
  RegFileWrite _ _ vId    -> dfltNV { alws = Just $ alwsRegFileWrite vId net }
  Custom p is os ps clked -> dfltNV { decl = Just $ sep
                                               [ declWire w (netInstId net, n)
                                               | ((o, w), n) <- zip os [0..] ]
                                    , inst = Just $
                                               instCustom net p is os ps clked }
  --_                       -> dfltNV
  where
  wId = (netInstId net, 0)
  dfltNV = NetVerilog { decl = Nothing
                      , inst = Nothing
                      , alws = Nothing
                      , rst  = Nothing }
  primNV = dfltNV { inst = Just $ instPrim net }
  -- general helpers
  --------------------------------------------------------------------------------
  genName :: Name -> String
  genName nm = if Set.null hints then "v"
               else intercalate "_" (Set.toList hints)
               where hints = nameHints nm
  showIntLit :: Int -> Integer -> Doc
  showIntLit w v = int w <> text "'h" <> hexInt v
  showDontCare :: Int -> Doc
  showDontCare w = int w <> text "'b" <> text (replicate w 'x')
  showWire :: (InstId, Int) -> Doc
  showWire (iId, nOut) =  text name <> char '_' <> int iId
                                    <> char '_' <> int nOut
                          where wNet = fromMaybe
                                  (error "Trying to show non existing Net")
                                  (netlist Data.Array.IArray.! iId)
                                name = genName $ netName wNet
  showWireWidth :: Int -> (InstId, Int) -> Doc
  showWireWidth width wId = brackets (int (width-1) <> text ":0") <+> showWire wId

  showPrim :: Prim -> [NetInput] -> Doc
  showPrim (Const w v) [] = showIntLit w v
  showPrim (DontCare w) [] = showDontCare w
  showPrim (Add _) [e0, e1] = showNetInput e0 <+> char '+' <+> showNetInput e1
  showPrim (Sub _) [e0, e1] = showNetInput e0 <+> char '-' <+> showNetInput e1
  showPrim (Mul _) [e0, e1] = showNetInput e0 <+> char '*' <+> showNetInput e1
  showPrim (Div _) [e0, e1] = showNetInput e0 <+> char '/' <+> showNetInput e1
  showPrim (Mod _) [e0, e1] = showNetInput e0 <+> char '%' <+> showNetInput e1
  showPrim (And _) [e0, e1] = showNetInput e0 <+> char '&' <+> showNetInput e1
  showPrim (Or _)  [e0, e1] = showNetInput e0 <+> char '|' <+> showNetInput e1
  showPrim (Xor _) [e0, e1] = showNetInput e0 <+> char '^' <+> showNetInput e1
  showPrim (Not _) [e0]     = char '~' <> showNetInput e0
  showPrim (ShiftLeft _) [e0, e1] =
    showNetInput e0 <+> text "<<" <+> showNetInput e1
  showPrim (ShiftRight _) [e0, e1] =
    showNetInput e0 <+> text ">>" <+> showNetInput e1
  showPrim (ArithShiftRight _) [e0, e1] =
    text "$signed" <> parens (showNetInput e0) <+> text ">>>" <+> showNetInput e1
  showPrim (Equal _) [e0, e1] = showNetInput e0 <+> text "==" <+> showNetInput e1
  showPrim (NotEqual _) [e0, e1] =
    showNetInput e0 <+> text "!=" <+> showNetInput e1
  showPrim (LessThan _) [e0, e1] =
    showNetInput e0 <+> char '<' <+> showNetInput e1
  showPrim (LessThanEq _) [e0, e1] =
    showNetInput e0 <+> text "<=" <+> showNetInput e1
  showPrim (ReplicateBit w) [e0] = braces $ int w <> braces (showNetInput e0)
  showPrim (ZeroExtend iw ow) [e0] =
    braces $ (braces $ int (ow-iw) <> braces (text "1'b0"))
          <> comma <+> showNetInput e0
  showPrim (SignExtend iw ow) [e0] =
    braces $ (braces $ int (ow-iw)
                    <> braces (showNetInput e0 <> brackets (int (iw-1))))
             <> comma <+> showNetInput e0
  showPrim (SelectBits _ hi lo) [e0] = case e0 of
    InputWire wId -> showWire wId <> brackets (int hi <> colon <> int lo)
    InputTree (Const _ v) [] ->
      showIntLit width ((v `shiftR` lo) .&. ((2^width)-1))
    InputTree (DontCare _) [] -> showDontCare width
    x -> error $
      "unsupported " ++ show x ++ " for SelectBits in Verilog generation"
    where width = hi+1-lo
  showPrim (Concat w0 w1) [e0, e1] =
    braces $ showNetInput e0 <> comma <+> showNetInput e1
  showPrim (Mux w) [sel, e0, e1] =
    showNetInput sel <+> char '?'
                     <+> showNetInput e0 <+> colon <+> showNetInput e1
  showPrim (CountOnes w) [e0] = text "$countones" <> parens (showNetInput e0)
  showPrim (Identity w) [e0] = showNetInput e0
  showPrim p _ = error $
    "unsupported Prim '" ++ show p ++ "' encountered in Verilog generation"

  showNetInput :: NetInput -> Doc
  showNetInput (InputWire wId) = showWire wId
  showNetInput (InputTree p@(Const _ _) ins) = showPrim p ins
  showNetInput (InputTree p@(DontCare _) ins) = showPrim p ins
  showNetInput (InputTree p@(Not _) ins) = showPrim p ins
  showNetInput (InputTree p@(ReplicateBit _) ins) = showPrim p ins
  showNetInput (InputTree p@(ZeroExtend _ _) ins) = showPrim p ins
  showNetInput (InputTree p@(SignExtend _ _) ins) = showPrim p ins
  showNetInput (InputTree p@(SelectBits _ _ _) ins) = showPrim p ins
  showNetInput (InputTree p@(Concat _ _) ins) = showPrim p ins
  showNetInput (InputTree p@(CountOnes _) ins) = showPrim p ins
  showNetInput (InputTree p@(Identity _) ins) = showPrim p ins
  showNetInput (InputTree p ins) = parens $ showPrim p ins

  -- declaration helpers
  --------------------------------------------------------------------------------
  declWire width wId = text "wire" <+> showWireWidth width wId <> semi
  declWireInit width wId init =     text "wire" <+> showWireWidth width wId
                                <+> equals <+> showIntLit width init <> semi
  declWireDontCare width wId  =     text "wire" <+> showWireWidth width wId
                                <+> equals <+> showDontCare width <> semi
  declReg width reg = text "reg" <+> showWireWidth width reg <> semi
  declRegInit width reg init =     text "reg" <+> showWireWidth width reg
                               <+> equals <+> showIntLit width init <> semi
  declRAM initFile numPorts _ dw net =
    vcat $ map (\n -> declWire dw (netInstId net, n)) [0..numPorts-1]
  declRegFile initFile aw dw id =
        text "reg" <+> brackets (int (dw-1) <> text ":0")
    <+> text "rf" <> int id
    <+> brackets (parens (text "2**" <> int aw) <> text "-1" <> text ":0") <> semi
    <> showInit
    where showInit = case initFile of
            ""    ->     text ""
            fname ->     text "\ngenerate initial $readmemh" <> parens
                         (text fname <> comma <+> text "rf" <> int id) <> semi
                     <+> text "endgenerate"

  -- reset helpers
  --------------------------------------------------------------------------------

  resetRegister width reg init =
        showWire reg <+> text "<="
    <+> int width <> text "'h" <> hexInt init <> semi

  -- instantiation helpers
  --------------------------------------------------------------------------------
  instPrim net =
        text "assign" <+> showWire (netInstId net, 0) <+> equals
    <+> showPrim (netPrim net) (netInputs net) <> semi
  instCustom net name ins outs params clked
    | numParams == 0 = hang (text name) 2 showInst
    | otherwise = hang (hang (text (name ++ "#")) 2 (parens $ argStyle allParams))
                    2 showInst
    where numParams = length params
          showInst = hang (text (name ++ "_") <> int nId) 2 (showArgs <> semi)
          allParams = [ dot <> text key <> parens (text val)
                      | (key :-> val, i) <- zip params [1..] ]
          args = zip ins (netInputs net) ++ [ (o, InputWire (nId, n))
                                            | (o, n) <- zip (map fst outs) [0..] ]
          numArgs  = length args
          showArgs = parens $ argStyle $ [ text ".clock(clock)" | clked ]
                                      ++ [ text ".reset(reset)" | clked ]
                                      ++ allArgs
          allArgs  = [ dot <> text name <> parens (showNetInput netInput)
                     | ((name, netInput), i) <- zip args [1..] ]
          nId = netInstId net
  instTestPlusArgs wId s =
        text "assign" <+> showWire wId <+> equals
    <+> text "$test$plusargs" <> parens (doubleQuotes $ text s)
    <+> text "== 0 ? 0 : 1;"
  instOutput net s =     text "assign" <+> text s
                     <+> equals <+> showNetInput (netInputs net !! 0) <> semi
  instInput net s =     text "assign" <+> showWire (netInstId net, 0)
                    <+> equals <+> text s <> semi
  instRAM net i aw dw =
        hang (hang (text "BlockRAM#") 2 (parens $ argStyle ramParams)) 2
          (hang (text "ram" <> int nId) 2 ((parens $ argStyle ramArgs) <> semi))
    where ramParams = [ text ".INIT_FILE"  <> parens (text (show $ fromMaybe "UNUSED" i))
                      , text ".ADDR_WIDTH" <> parens (int aw)
                      , text ".DATA_WIDTH" <> parens (int dw) ]
          ramArgs   = [ text ".CLK(clock)"
                      , text ".DI"   <> parens (showNetInput (netInputs net !! 1))
                      , text ".ADDR" <> parens (showNetInput (netInputs net !! 0))
                      , text ".WE"   <> parens (showNetInput (netInputs net !! 2))
                      , text ".DO"   <> parens (showWire (nId, 0)) ]
          nId = netInstId net
  instTrueDualRAM net i aw dw =
        hang (hang (text "BlockRAMTrueDual#") 2 (parens $ argStyle ramParams)) 2
          (hang (text "ram" <> int nId) 2 ((parens $ argStyle ramArgs) <> semi))
    where ramParams = [ text ".INIT_FILE"  <> parens (text (show $ fromMaybe "UNUSED" i))
                      , text ".ADDR_WIDTH" <> parens (int aw)
                      , text ".DATA_WIDTH" <> parens (int dw) ]
          ramArgs   = [ text ".CLK(clock)"
                      , text ".DI_A"   <> parens (showNetInput (netInputs net !! 1))
                      , text ".ADDR_A" <> parens (showNetInput (netInputs net !! 0))
                      , text ".WE_A"   <> parens (showNetInput (netInputs net !! 2))
                      , text ".DO_A"   <> parens (showWire (nId, 0))
                      , text ".DI_B"   <> parens (showNetInput (netInputs net !! 4))
                      , text ".ADDR_B" <> parens (showNetInput (netInputs net !! 3))
                      , text ".WE_B"   <> parens (showNetInput (netInputs net !! 5))
                      , text ".DO_B"   <> parens (showWire (nId, 1)) ]
          nId = netInstId net
  instRegFileRead id net =
        text "assign" <+> showWire (netInstId net, 0)
    <+> equals <+> text "rf" <> int id
    <>  brackets (showNetInput (netInputs net !! 0)) <> semi

  -- always block helpers
  --------------------------------------------------------------------------------
  alwsRegister net = showWire (netInstId net, 0) <+> text "<="
                 <+> showNetInput (netInputs net !! 0) <> semi
  alwsRegisterEn net =
        text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
    <+> showWire (netInstId net, 0)
    <+> text "<=" <+> showNetInput (netInputs net !! 1) <>  semi
  alwsDisplay args net =
        hang (    text "if"
              <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
              <+> text "$write")
             2 ((parens (argStyle $ fmtArgs args (tail $ netInputs net))) <> semi)
    where fmtArgs [] _ = []
          fmtArgs (DisplayArgString s : args) ins =
            (text $ shows s "") : (fmtArgs args ins)
          fmtArgs (DisplayArgBit w : args) (x:ins) =
            (showNetInput x) : (fmtArgs args ins)
  alwsFinish net =
    text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
             <+> text "$finish" <> semi
  alwsRegFileWrite id net =
        text "if" <+> parens (showNetInput (netInputs net !! 0) <+> text "== 1")
    <+> text "rf" <> int id <> brackets (showNetInput (netInputs net !! 1))
    <+> text "<=" <+> showNetInput (netInputs net !! 2) <> semi
