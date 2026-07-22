unit Pdp11DisasU;
{
  Native PDP-11 disassembler engine.

  Replaces the Windows-only PDP11DISAS.DLL that Pdp11gui/FormDisasU.pas used
  to call (source unavailable, see LINUX_PORT_TODO.md). Covers the full
  PDP-11 instruction set: base ISA, EIS (MUL/DIV/ASH/ASHC/XOR/SOB), FP11
  floating point, and the Commercial Instruction Set (CIS).

  The opcode/mask/operand-format table below was cross-checked against
  SimH's open-source PDP-11 simulator (PDP11/pdp11_sys.c: opcode[]/
  opc_val[]/masks[]/fprint_sym/fprint_spec) -- a well-tested reference for
  the publicly documented DEC PDP-11 instruction set encoding. This is a
  fresh Pascal implementation of that same, publicly-documented ISA (not a
  copy of SimH's C code or text); the condition-code-instruction mnemonics
  (opcodes 000240-000277, "CLZ CLV" etc.) are derived directly from the
  documented per-flag bit encoding rather than from SimH's opcode[] strings,
  which have a verified copy-paste duplicate at opcode 000256.

  Known limitations (both inherent to *static* disassembly, not bugs):

  - FP11 F/D (single/double precision) and I/L (integer/long) instruction
    variants share IDENTICAL opcode bits -- the distinction is carried by
    the CPU's live FPS mode register, which this disassembler has no access
    to (it only sees a memory image). We always print the F/I ("single
    precision", the FP11 power-on default) mnemonic. The D/L-variant table
    entries are kept below (their OpVal has bit16/17 set, so they can never
    match a plain 16-bit instruction word) purely for completeness/
    documentation, and so a future caller with access to a live FPS value
    could enable them by OR-ing FPS_D ($20000) / FPS_L ($10000) into the
    word passed to DisassembleInstruction.

  - CIS "inline" instructions (mnemonics ending in "I", e.g. MOVCI, ADDNI)
    embed their descriptor operands as data words directly following the
    opcode, rather than in fixed registers. Decoding those descriptors
    would require modelling CIS's variable-length packed/numeric descriptor
    formats. We print the mnemonic only, one word consumed (matching SimH's
    own disassembler) -- the descriptor words that structurally follow will
    show up as their own (likely nonsensical) disassembled/data lines.
    Non-inline CIS instructions (MOVC, LOCC, ADDN, CVTPL, ASHP, ...) are
    unaffected: their operands are always in fixed registers (R0:R1 etc.)
    by architectural convention, so they're genuinely complete as printed.
}

interface

// Disassembles the instruction at 'addr'. coremem/coremem_valid are 64K
// byte images (little-endian PDP-11 words); coremem_valid[i]<>#0 marks
// byte i as containing real data. Returns the number of words consumed
// (>=1) and the decoded "MNEMONIC operands" text (no address, no raw
// words -- the caller adds those). Falls back to ".WORD nnnnnn" (1 word)
// for unrecognized opcodes or when a required extension word isn't valid.
function DisassembleInstruction(coremem, coremem_valid: PAnsiChar;
        addr: word; out text: string): integer;

// DLL-ABI-compatible entry point (matches the old PDP11DISAS.DLL signature
// that FormDisasU.pas's stub still declares): walks the whole 64K image,
// skipping addresses whose memory isn't valid, and fills srcbuff with one
// disassembled line per instruction:
//   "AAAAAA: WWWWWW WWWWWW WWWWWW  MNEMONIC operands\n"
// (address, up to 3 raw instruction words blank-padded, then the decode).
procedure Disas11(
        srcbuff: PAnsiChar; srcbuff_size: integer;
        coremem: PAnsiChar; coremem_valid: PAnsiChar; coremem_size: integer);

implementation

uses
  SysUtils;

type
  // One entry per addressing/operand shape a PDP-11 instruction can have.
  // Mirrors SimH's I_V_xxx classes (pdp11_sys.c); see the case statement
  // in DisassembleInstruction for exactly how each one is printed.
  TOpClass = (
    clsNPN,   // no operand (HALT, RTI, MOVC, ...)
    clsREG,   // "opcode Rn" (RTS, FADD, L2DR, ...)
    clsSOP,   // "opcode operand" (CLR, TST, JMP, MFPI, ...)
    cls3B,    // "opcode n" -- 3-bit literal (SPL)
    cls6B,    // "opcode n" -- 6-bit literal (MARK)
    cls8B,    // "opcode n" -- 8-bit literal (EMT, TRAP)
    clsBR,    // "opcode target" -- conditional branch
    clsSOB,   // "opcode Rn,target" -- SOB (backward branch)
    clsDOP,   // "opcode src,dst" (MOV, CMP, ADD, ...)
    clsRSOP,  // "opcode Rn,operand" (JSR, XOR)
    clsSOPR,  // "opcode operand,Rn" (MUL, DIV, ASH, ASHC)
    clsCCC,   // condition-code clear group; decodes exactly like clsNPN
    clsCCS,   // condition-code set group; decodes exactly like clsNPN
    clsFOP,   // "opcode fltoperand" (CLRF, TSTF, ABSF, NEGF, ...)
    clsAFOP,  // "opcode ACn,fltoperand" (STF, STCFD, ...)
    clsFOPA,  // "opcode fltoperand,ACn" (ADDF, MULF, LDF, SUBF, CMPF, DIVF, MODF, LDCFD)
    clsASOP,  // "opcode ACn,intoperand" (STEXP)
    clsASMD,  // "opcode ACn,intoperand" (STCFI family)
    clsSOPA,  // "opcode intoperand,ACn" (LDEXP)
    clsSMDA   // "opcode intoperand,ACn" (LDCIF family)
  );

  TOpEntry = record
    Name: string;
    OpVal: dword; // may have bit16 (FPS_L) / bit17 (FPS_D) set; see header comment
    Mask: dword;
    Cls: TOpClass;
  end;

const
  FPS_L = $10000;
  FPS_D = $20000;

  // Verified 1:1 against SimH's opcode[]/opc_val[]/masks[] (pdp11_sys.c),
  // pulled programmatically (not transcribed by eye) -- see unit header.
  OpTable: array[0..216] of TOpEntry = (
    (Name:'HALT'; OpVal:$0000; Mask:$0ffff; Cls:clsNPN),
    (Name:'WAIT'; OpVal:$0001; Mask:$0ffff; Cls:clsNPN),
    (Name:'RTI'; OpVal:$0002; Mask:$0ffff; Cls:clsNPN),
    (Name:'BPT'; OpVal:$0003; Mask:$0ffff; Cls:clsNPN),
    (Name:'IOT'; OpVal:$0004; Mask:$0ffff; Cls:clsNPN),
    (Name:'RESET'; OpVal:$0005; Mask:$0ffff; Cls:clsNPN),
    (Name:'RTT'; OpVal:$0006; Mask:$0ffff; Cls:clsNPN),
    (Name:'MFPT'; OpVal:$0007; Mask:$0ffff; Cls:clsNPN),
    (Name:'JMP'; OpVal:$0040; Mask:$0ffc0; Cls:clsSOP),
    (Name:'RTS'; OpVal:$0080; Mask:$0fff8; Cls:clsREG),
    (Name:'SPL'; OpVal:$0098; Mask:$0fff8; Cls:cls3B),
    (Name:'NOP'; OpVal:$00a0; Mask:$0ffff; Cls:clsCCC),
    (Name:'CLC'; OpVal:$00a1; Mask:$0ffff; Cls:clsCCC),
    (Name:'CLV'; OpVal:$00a2; Mask:$0ffff; Cls:clsCCC),
    (Name:'CLV CLC'; OpVal:$00a3; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLZ'; OpVal:$00a4; Mask:$0ffff; Cls:clsCCC),
    (Name:'CLZ CLC'; OpVal:$00a5; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLZ CLV'; OpVal:$00a6; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLZ CLV CLC'; OpVal:$00a7; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN'; OpVal:$00a8; Mask:$0ffff; Cls:clsCCC),
    (Name:'CLN CLC'; OpVal:$00a9; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN CLV'; OpVal:$00aa; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN CLV CLC'; OpVal:$00ab; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN CLZ'; OpVal:$00ac; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN CLZ CLC'; OpVal:$00ad; Mask:$0ffff; Cls:clsNPN),
    (Name:'CLN CLZ CLV'; OpVal:$00ae; Mask:$0ffff; Cls:clsNPN),
    (Name:'CCC'; OpVal:$00af; Mask:$0ffff; Cls:clsCCC),
    (Name:'NOP'; OpVal:$00b0; Mask:$0ffff; Cls:clsCCS),
    (Name:'SEC'; OpVal:$00b1; Mask:$0ffff; Cls:clsCCS),
    (Name:'SEV'; OpVal:$00b2; Mask:$0ffff; Cls:clsCCS),
    (Name:'SEV SEC'; OpVal:$00b3; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEZ'; OpVal:$00b4; Mask:$0ffff; Cls:clsCCS),
    (Name:'SEZ SEC'; OpVal:$00b5; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEZ SEV'; OpVal:$00b6; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEZ SEV SEC'; OpVal:$00b7; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN'; OpVal:$00b8; Mask:$0ffff; Cls:clsCCS),
    (Name:'SEN SEC'; OpVal:$00b9; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN SEV'; OpVal:$00ba; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN SEV SEC'; OpVal:$00bb; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN SEZ'; OpVal:$00bc; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN SEZ SEC'; OpVal:$00bd; Mask:$0ffff; Cls:clsNPN),
    (Name:'SEN SEZ SEV'; OpVal:$00be; Mask:$0ffff; Cls:clsNPN),
    (Name:'SCC'; OpVal:$00bf; Mask:$0ffff; Cls:clsCCS),
    (Name:'SWAB'; OpVal:$00c0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'BR'; OpVal:$0100; Mask:$0ff00; Cls:clsBR),
    (Name:'BNE'; OpVal:$0200; Mask:$0ff00; Cls:clsBR),
    (Name:'BEQ'; OpVal:$0300; Mask:$0ff00; Cls:clsBR),
    (Name:'BGE'; OpVal:$0400; Mask:$0ff00; Cls:clsBR),
    (Name:'BLT'; OpVal:$0500; Mask:$0ff00; Cls:clsBR),
    (Name:'BGT'; OpVal:$0600; Mask:$0ff00; Cls:clsBR),
    (Name:'BLE'; OpVal:$0700; Mask:$0ff00; Cls:clsBR),
    (Name:'JSR'; OpVal:$0800; Mask:$0fe00; Cls:clsRSOP),
    (Name:'CLR'; OpVal:$0a00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'COM'; OpVal:$0a40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'INC'; OpVal:$0a80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'DEC'; OpVal:$0ac0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'NEG'; OpVal:$0b00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ADC'; OpVal:$0b40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'SBC'; OpVal:$0b80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'TST'; OpVal:$0bc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ROR'; OpVal:$0c00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ROL'; OpVal:$0c40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ASR'; OpVal:$0c80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ASL'; OpVal:$0cc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MARK'; OpVal:$0d00; Mask:$0ffc0; Cls:cls6B),
    (Name:'MFPI'; OpVal:$0d40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MTPI'; OpVal:$0d80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'SXT'; OpVal:$0dc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'CSM'; OpVal:$0e00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'TSTSET'; OpVal:$0e80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'WRTLCK'; OpVal:$0ec0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MOV'; OpVal:$1000; Mask:$0f000; Cls:clsDOP),
    (Name:'CMP'; OpVal:$2000; Mask:$0f000; Cls:clsDOP),
    (Name:'BIT'; OpVal:$3000; Mask:$0f000; Cls:clsDOP),
    (Name:'BIC'; OpVal:$4000; Mask:$0f000; Cls:clsDOP),
    (Name:'BIS'; OpVal:$5000; Mask:$0f000; Cls:clsDOP),
    (Name:'ADD'; OpVal:$6000; Mask:$0f000; Cls:clsDOP),
    (Name:'MUL'; OpVal:$7000; Mask:$0fe00; Cls:clsSOPR),
    (Name:'DIV'; OpVal:$7200; Mask:$0fe00; Cls:clsSOPR),
    (Name:'ASH'; OpVal:$7400; Mask:$0fe00; Cls:clsSOPR),
    (Name:'ASHC'; OpVal:$7600; Mask:$0fe00; Cls:clsSOPR),
    (Name:'XOR'; OpVal:$7800; Mask:$0fe00; Cls:clsRSOP),
    (Name:'FADD'; OpVal:$7a00; Mask:$0fff8; Cls:clsREG),
    (Name:'FSUB'; OpVal:$7a08; Mask:$0fff8; Cls:clsREG),
    (Name:'FMUL'; OpVal:$7a10; Mask:$0fff8; Cls:clsREG),
    (Name:'FDIV'; OpVal:$7a18; Mask:$0fff8; Cls:clsREG),
    (Name:'L2DR'; OpVal:$7c10; Mask:$0fff8; Cls:clsREG),
    (Name:'MOVC'; OpVal:$7c18; Mask:$0ffff; Cls:clsNPN),
    (Name:'MOVRC'; OpVal:$7c19; Mask:$0ffff; Cls:clsNPN),
    (Name:'MOVTC'; OpVal:$7c1a; Mask:$0ffff; Cls:clsNPN),
    (Name:'LOCC'; OpVal:$7c20; Mask:$0ffff; Cls:clsNPN),
    (Name:'SKPC'; OpVal:$7c21; Mask:$0ffff; Cls:clsNPN),
    (Name:'SCANC'; OpVal:$7c22; Mask:$0ffff; Cls:clsNPN),
    (Name:'SPANC'; OpVal:$7c23; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPC'; OpVal:$7c24; Mask:$0ffff; Cls:clsNPN),
    (Name:'MATC'; OpVal:$7c25; Mask:$0ffff; Cls:clsNPN),
    (Name:'ADDN'; OpVal:$7c28; Mask:$0ffff; Cls:clsNPN),
    (Name:'SUBN'; OpVal:$7c29; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPN'; OpVal:$7c2a; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTNL'; OpVal:$7c2b; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTPN'; OpVal:$7c2c; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTNP'; OpVal:$7c2d; Mask:$0ffff; Cls:clsNPN),
    (Name:'ASHN'; OpVal:$7c2e; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTLN'; OpVal:$7c2f; Mask:$0ffff; Cls:clsNPN),
    (Name:'L3DR'; OpVal:$7c30; Mask:$0fff8; Cls:clsREG),
    (Name:'ADDP'; OpVal:$7c38; Mask:$0ffff; Cls:clsNPN),
    (Name:'SUBP'; OpVal:$7c39; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPP'; OpVal:$7c3a; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTPL'; OpVal:$7c3b; Mask:$0ffff; Cls:clsNPN),
    (Name:'MULP'; OpVal:$7c3c; Mask:$0ffff; Cls:clsNPN),
    (Name:'DIVP'; OpVal:$7c3d; Mask:$0ffff; Cls:clsNPN),
    (Name:'ASHP'; OpVal:$7c3e; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTLP'; OpVal:$7c3f; Mask:$0ffff; Cls:clsNPN),
    (Name:'MOVCI'; OpVal:$7c58; Mask:$0ffff; Cls:clsNPN),
    (Name:'MOVRCI'; OpVal:$7c59; Mask:$0ffff; Cls:clsNPN),
    (Name:'MOVTCI'; OpVal:$7c5a; Mask:$0ffff; Cls:clsNPN),
    (Name:'LOCCI'; OpVal:$7c60; Mask:$0ffff; Cls:clsNPN),
    (Name:'SKPCI'; OpVal:$7c61; Mask:$0ffff; Cls:clsNPN),
    (Name:'SCANCI'; OpVal:$7c62; Mask:$0ffff; Cls:clsNPN),
    (Name:'SPANCI'; OpVal:$7c63; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPCI'; OpVal:$7c64; Mask:$0ffff; Cls:clsNPN),
    (Name:'MATCI'; OpVal:$7c65; Mask:$0ffff; Cls:clsNPN),
    (Name:'ADDNI'; OpVal:$7c68; Mask:$0ffff; Cls:clsNPN),
    (Name:'SUBNI'; OpVal:$7c69; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPNI'; OpVal:$7c6a; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTNLI'; OpVal:$7c6b; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTPNI'; OpVal:$7c6c; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTNPI'; OpVal:$7c6d; Mask:$0ffff; Cls:clsNPN),
    (Name:'ASHNI'; OpVal:$7c6e; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTLNI'; OpVal:$7c6f; Mask:$0ffff; Cls:clsNPN),
    (Name:'ADDPI'; OpVal:$7c78; Mask:$0ffff; Cls:clsNPN),
    (Name:'SUBPI'; OpVal:$7c79; Mask:$0ffff; Cls:clsNPN),
    (Name:'CMPPI'; OpVal:$7c7a; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTPLI'; OpVal:$7c7b; Mask:$0ffff; Cls:clsNPN),
    (Name:'MULPI'; OpVal:$7c7c; Mask:$0ffff; Cls:clsNPN),
    (Name:'DIVPI'; OpVal:$7c7d; Mask:$0ffff; Cls:clsNPN),
    (Name:'ASHPI'; OpVal:$7c7e; Mask:$0ffff; Cls:clsNPN),
    (Name:'CVTLPI'; OpVal:$7c7f; Mask:$0ffff; Cls:clsNPN),
    (Name:'SOB'; OpVal:$7e00; Mask:$0fe00; Cls:clsSOB),
    (Name:'BPL'; OpVal:$8000; Mask:$0ff00; Cls:clsBR),
    (Name:'BMI'; OpVal:$8100; Mask:$0ff00; Cls:clsBR),
    (Name:'BHI'; OpVal:$8200; Mask:$0ff00; Cls:clsBR),
    (Name:'BLOS'; OpVal:$8300; Mask:$0ff00; Cls:clsBR),
    (Name:'BVC'; OpVal:$8400; Mask:$0ff00; Cls:clsBR),
    (Name:'BVS'; OpVal:$8500; Mask:$0ff00; Cls:clsBR),
    (Name:'BCC'; OpVal:$8600; Mask:$0ff00; Cls:clsBR),
    (Name:'BCS'; OpVal:$8700; Mask:$0ff00; Cls:clsBR),
    (Name:'EMT'; OpVal:$8800; Mask:$0ff00; Cls:cls8B),
    (Name:'TRAP'; OpVal:$8900; Mask:$0ff00; Cls:cls8B),
    (Name:'CLRB'; OpVal:$8a00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'COMB'; OpVal:$8a40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'INCB'; OpVal:$8a80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'DECB'; OpVal:$8ac0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'NEGB'; OpVal:$8b00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ADCB'; OpVal:$8b40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'SBCB'; OpVal:$8b80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'TSTB'; OpVal:$8bc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'RORB'; OpVal:$8c00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ROLB'; OpVal:$8c40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ASRB'; OpVal:$8c80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'ASLB'; OpVal:$8cc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MTPS'; OpVal:$8d00; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MFPD'; OpVal:$8d40; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MTPD'; OpVal:$8d80; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MFPS'; OpVal:$8dc0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'MOVB'; OpVal:$9000; Mask:$0f000; Cls:clsDOP),
    (Name:'CMPB'; OpVal:$a000; Mask:$0f000; Cls:clsDOP),
    (Name:'BITB'; OpVal:$b000; Mask:$0f000; Cls:clsDOP),
    (Name:'BICB'; OpVal:$c000; Mask:$0f000; Cls:clsDOP),
    (Name:'BISB'; OpVal:$d000; Mask:$0f000; Cls:clsDOP),
    (Name:'SUB'; OpVal:$e000; Mask:$0f000; Cls:clsDOP),
    (Name:'CFCC'; OpVal:$f000; Mask:$0ffff; Cls:clsNPN),
    (Name:'SETF'; OpVal:$f001; Mask:$0ffff; Cls:clsNPN),
    (Name:'SETI'; OpVal:$f002; Mask:$0ffff; Cls:clsNPN),
    (Name:'SETD'; OpVal:$f009; Mask:$0ffff; Cls:clsNPN),
    (Name:'SETL'; OpVal:$f00a; Mask:$0ffff; Cls:clsNPN),
    (Name:'LDFPS'; OpVal:$f040; Mask:$0ffc0; Cls:clsSOP),
    (Name:'STFPS'; OpVal:$f080; Mask:$0ffc0; Cls:clsSOP),
    (Name:'STST'; OpVal:$f0c0; Mask:$0ffc0; Cls:clsSOP),
    (Name:'CLRF'; OpVal:$f100; Mask:$2ffc0; Cls:clsFOP),
    (Name:'CLRD'; OpVal:$2f100; Mask:$2ffc0; Cls:clsFOP),
    (Name:'TSTF'; OpVal:$f140; Mask:$2ffc0; Cls:clsFOP),
    (Name:'TSTD'; OpVal:$2f140; Mask:$2ffc0; Cls:clsFOP),
    (Name:'ABSF'; OpVal:$f180; Mask:$2ffc0; Cls:clsFOP),
    (Name:'ABSD'; OpVal:$2f180; Mask:$2ffc0; Cls:clsFOP),
    (Name:'NEGF'; OpVal:$f1c0; Mask:$2ffc0; Cls:clsFOP),
    (Name:'NEGD'; OpVal:$2f1c0; Mask:$2ffc0; Cls:clsFOP),
    (Name:'MULF'; OpVal:$f200; Mask:$2ff00; Cls:clsFOPA),
    (Name:'MULD'; OpVal:$2f200; Mask:$2ff00; Cls:clsFOPA),
    (Name:'MODF'; OpVal:$f300; Mask:$2ff00; Cls:clsFOPA),
    (Name:'MODD'; OpVal:$2f300; Mask:$2ff00; Cls:clsFOPA),
    (Name:'ADDF'; OpVal:$f400; Mask:$2ff00; Cls:clsFOPA),
    (Name:'ADDD'; OpVal:$2f400; Mask:$2ff00; Cls:clsFOPA),
    (Name:'LDF'; OpVal:$f500; Mask:$2ff00; Cls:clsFOPA),
    (Name:'LDD'; OpVal:$2f500; Mask:$2ff00; Cls:clsFOPA),
    (Name:'SUBF'; OpVal:$f600; Mask:$2ff00; Cls:clsFOPA),
    (Name:'SUBD'; OpVal:$2f600; Mask:$2ff00; Cls:clsFOPA),
    (Name:'CMPF'; OpVal:$f700; Mask:$2ff00; Cls:clsFOPA),
    (Name:'CMPD'; OpVal:$2f700; Mask:$2ff00; Cls:clsFOPA),
    (Name:'STF'; OpVal:$f800; Mask:$2ff00; Cls:clsAFOP),
    (Name:'STD'; OpVal:$2f800; Mask:$2ff00; Cls:clsAFOP),
    (Name:'DIVF'; OpVal:$f900; Mask:$2ff00; Cls:clsFOPA),
    (Name:'DIVD'; OpVal:$2f900; Mask:$2ff00; Cls:clsFOPA),
    (Name:'STEXP'; OpVal:$fa00; Mask:$0ff00; Cls:clsASOP),
    (Name:'STCFI'; OpVal:$fb00; Mask:$3ff00; Cls:clsASMD),
    (Name:'STCDI'; OpVal:$2fb00; Mask:$3ff00; Cls:clsASMD),
    (Name:'STCFL'; OpVal:$1fb00; Mask:$3ff00; Cls:clsASMD),
    (Name:'STCDL'; OpVal:$3fb00; Mask:$3ff00; Cls:clsASMD),
    (Name:'STCFD'; OpVal:$fc00; Mask:$2ff00; Cls:clsAFOP),
    (Name:'STCDF'; OpVal:$2fc00; Mask:$2ff00; Cls:clsAFOP),
    (Name:'LDEXP'; OpVal:$fd00; Mask:$0ff00; Cls:clsSOPA),
    (Name:'LDCIF'; OpVal:$fe00; Mask:$3ff00; Cls:clsSMDA),
    (Name:'LDCID'; OpVal:$2fe00; Mask:$3ff00; Cls:clsSMDA),
    (Name:'LDCLF'; OpVal:$1fe00; Mask:$3ff00; Cls:clsSMDA),
    (Name:'LDCLD'; OpVal:$3fe00; Mask:$3ff00; Cls:clsSMDA),
    (Name:'LDCFD'; OpVal:$ff00; Mask:$2ff00; Cls:clsFOPA),
    (Name:'LDCDF'; OpVal:$2ff00; Mask:$2ff00; Cls:clsFOPA)
  );

  RegNames: array[0..7] of string = ('R0','R1','R2','R3','R4','R5','SP','PC');


function RegName(r: byte): string; inline;
  begin
    result := RegNames[r and 7] ;
  end;

// FP11 accumulator name. The "fac" field in the instruction is only 2 bits
// wide (AC0..AC3) for every instruction class that uses it -- see the FP11
// architecture handbook double-operand instruction format.
function FacName(f: byte): string; inline;
  begin
    result := 'AC' + IntToStr(f and 3) ;
  end;

function WordValid(coremem_valid: PAnsiChar; addr: word): boolean; inline;
  begin
    result := (coremem_valid[addr] <> #0) and (coremem_valid[word(addr+1)] <> #0) ;
  end;

function ReadWord(coremem: PAnsiChar; addr: word): word; inline;
  begin
    result := word(byte(coremem[addr])) or (word(byte(coremem[word(addr+1)])) shl 8) ;
  end;

// Zero-padded octal string, 'digits' wide (0 = no padding, minimal width).
// Local equivalent of JH_Utilities.Dword2OctalStr -- not reused directly so
// this unit doesn't have to pull in JH_Utilities' LCL (Controls) dependency
// for one small formatting helper.
function DwordToOctalStr(val: dword; digits: integer): string;
  begin
    result := '' ;
    repeat
      result := char((val and 7) + ord('0')) + result ;
      val := val shr 3 ;
    until val = 0 ;
    while length(result) < digits do
      result := '0' + result ;
  end;

// Fixed-width 6-digit octal (addresses, absolute/relative targets, literal words)
function OctW(w: word): string; inline;
  begin
    result := DwordToOctalStr(w, 6) ;
  end;

// Minimal-width octal (3b/6b/8b literal instruction fields)
function OctPlain(v: word): string; inline;
  begin
    result := DwordToOctalStr(v, 0) ;
  end;

// Decodes one 6-bit addressing-mode specifier (3-bit mode + 3-bit register).
// 'cursor' points at the next unconsumed word in the instruction stream and
// is advanced past any extension word this operand consumes. 'isInteger'
// selects whether mode-0 (register direct) names a general register (Rn,
// the normal case) or an FP11 accumulator (ACn -- used by float operands,
// where the CPU addresses its own AC file directly in this one mode; see
// FP11 handbook). On failure (a needed extension word isn't valid memory),
// sets ok=false and returns '' -- the caller then falls back to .WORD.
function DecodeOperand(coremem, coremem_valid: PAnsiChar;
        spec: byte; isInteger: boolean; var cursor: word; var ok: boolean): string;
  var
    reg, mode: byte;
    nval, target: word;
  begin
    result := '' ;
    if not ok then exit ;

    reg := spec and 7 ;
    mode := (spec shr 3) and 7 ;

    case mode of
      0:
        if isInteger then result := RegName(reg) else result := FacName(reg) ;

      1:
        result := '(' + RegName(reg) + ')' ;

      2:
        if reg <> 7 then
          result := '(' + RegName(reg) + ')+'
        else begin
          if not WordValid(coremem_valid, cursor) then begin ok := false ; exit ; end ;
          nval := ReadWord(coremem, cursor) ;
          cursor := word(cursor + 2) ;
          result := '#' + OctW(nval) ;
        end;

      3:
        if reg <> 7 then
          result := '@(' + RegName(reg) + ')+'
        else begin
          if not WordValid(coremem_valid, cursor) then begin ok := false ; exit ; end ;
          nval := ReadWord(coremem, cursor) ;
          cursor := word(cursor + 2) ;
          result := '@#' + OctW(nval) ;
        end;

      4:
        result := '-(' + RegName(reg) + ')' ;

      5:
        result := '@-(' + RegName(reg) + ')' ;

      6: begin
          if not WordValid(coremem_valid, cursor) then begin ok := false ; exit ; end ;
          nval := ReadWord(coremem, cursor) ;
          cursor := word(cursor + 2) ;
          if reg <> 7 then
            result := OctW(nval) + '(' + RegName(reg) + ')'
          else begin
            target := word(nval + cursor) ; // cursor already advanced == PC right after this word's fetch
            result := OctW(target) ;
          end;
        end;

      7: begin
          if not WordValid(coremem_valid, cursor) then begin ok := false ; exit ; end ;
          nval := ReadWord(coremem, cursor) ;
          cursor := word(cursor + 2) ;
          if reg <> 7 then
            result := '@' + OctW(nval) + '(' + RegName(reg) + ')'
          else begin
            target := word(nval + cursor) ;
            result := '@' + OctW(target) ;
          end;
        end;
      end{ "case mode" } ;
  end{ "function DecodeOperand" } ;


function DisassembleInstruction(coremem, coremem_valid: PAnsiChar;
        addr: word; out text: string): integer;
  var
    w: dword ; // zero-extended instruction word; bits 16/17 always 0 (see unit header)
    i, idx: integer ;
    cls: TOpClass ;
    mnemonic, operands, s1, s2: string ;
    cursor: word ;
    ok: boolean ;
    srcSpec, dstSpec, reg3, fac2: byte ;
    lit8: byte ;
    brOfs: shortint ;
    target: word ;
  begin
    w := ReadWord(coremem, addr) ;

    idx := -1 ;
    for i := low(OpTable) to high(OpTable) do
      if (w and OpTable[i].Mask) = OpTable[i].OpVal then begin
        idx := i ;
        break ;
      end;

    if idx < 0 then begin
      text := LowerCase(Format('%-8s%s', ['.WORD', OctW(word(w))])) ;
      result := 1 ;
      exit ;
    end;

    mnemonic := OpTable[idx].Name ;
    cls := OpTable[idx].Cls ;

    srcSpec := (w shr 6) and $3f ; // "SS" field, bits 11-6
    dstSpec := w and $3f ;         // "DD" field, bits 5-0
    reg3    := srcSpec and 7 ;     // 3-bit register (RSOP/SOPR/SOB/REG/3B classes)
    fac2    := (w shr 6) and 3 ;   // 2-bit FP11 accumulator number
    lit8    := w and $ff ;

    cursor := word(addr + 2) ;
    ok := true ;
    operands := '' ;
    s1 := '' ; s2 := '' ;

    case cls of
      clsNPN, clsCCC, clsCCS:
        ; // mnemonic only

      clsREG:
        operands :=RegName(dstSpec and 7) ;

      cls3B:
        operands :=OctPlain(reg3) ;

      cls6B:
        operands :=OctPlain(dstSpec) ;

      cls8B:
        operands :=OctPlain(lit8) ;

      clsBR: begin
          brOfs := shortint(lit8) ;
          target := word(addr + 2 + 2*integer(brOfs)) ;
          operands :=OctW(target) ;
        end;

      clsSOB: begin
          target := word(addr + 2 - 2*dstSpec) ;
          operands :=RegName(reg3) + ',' + OctW(target) ;
        end;

      clsSOP:
        operands :=DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;

      clsFOP:
        operands :=DecodeOperand(coremem, coremem_valid, dstSpec, false, cursor, ok) ;

      clsDOP: begin
          s1 := DecodeOperand(coremem, coremem_valid, srcSpec, true, cursor, ok) ;
          s2 := DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;
          operands :=s1 + ',' + s2 ;
        end;

      clsRSOP: begin // JSR Rn,dst / XOR Rn,dst
          s2 := DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;
          operands :=RegName(reg3) + ',' + s2 ;
        end;

      clsSOPR: begin // MUL/DIV/ASH/ASHC src,Rn
          s1 := DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;
          operands :=s1 + ',' + RegName(reg3) ;
        end;

      clsAFOP: begin // STF/STD/STCFD/STCDF: ACn,operand
          s2 := DecodeOperand(coremem, coremem_valid, dstSpec, false, cursor, ok) ;
          operands :=FacName(fac2) + ',' + s2 ;
        end;

      clsFOPA: begin // ADDF/MULF/SUBF/CMPF/DIVF/MODF/LDF/LDCFD: operand,ACn
          s1 := DecodeOperand(coremem, coremem_valid, dstSpec, false, cursor, ok) ;
          operands :=s1 + ',' + FacName(fac2) ;
        end;

      clsASOP, clsASMD: begin // STEXP/STCFI family: ACn,operand (integer dest)
          s2 := DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;
          operands :=FacName(fac2) + ',' + s2 ;
        end;

      clsSOPA, clsSMDA: begin // LDEXP/LDCIF family: operand,ACn (integer src)
          s1 := DecodeOperand(coremem, coremem_valid, dstSpec, true, cursor, ok) ;
          operands :=s1 + ',' + FacName(fac2) ;
        end;
      end{ "case cls" } ;

    if not ok then begin
      text := LowerCase(Format('%-8s%s', ['.WORD', OctW(word(w))])) ;
      result := 1 ;
      exit ;
    end;

    text := LowerCase(Format('%-8s%s', [mnemonic, operands])) ;
    result := ((integer(cursor) - integer(addr) + 65536) mod 65536) div 2 ;
  end{ "function DisassembleInstruction" } ;


procedure Disas11(
        srcbuff: PAnsiChar; srcbuff_size: integer;
        coremem: PAnsiChar; coremem_valid: PAnsiChar; coremem_size: integer);
  var
    addrInt, wordsUsed, i, bufpos: integer ;
    addr: word ;
    text, line, rawwords: string ;
  begin
    FillChar(srcbuff^, srcbuff_size, 0) ;
    bufpos := 0 ;

    addrInt := 0 ;
    while addrInt <= coremem_size - 2 do begin
      addr := word(addrInt) ;

      if WordValid(coremem_valid, addr) then begin
        wordsUsed := DisassembleInstruction(coremem, coremem_valid, addr, text) ;

        rawwords := '' ;
        for i := 0 to 2 do
          if i < wordsUsed then
            rawwords := rawwords + OctW(ReadWord(coremem, word(addr + i*2))) + ' '
          else
            rawwords := rawwords + '       ' ;

        line := OctW(addr) + ': ' + rawwords + ' ' + text ;

        if bufpos + length(line) + 1 >= srcbuff_size then
          break ;
        Move(line[1], (srcbuff+bufpos)^, length(line)) ;
        inc(bufpos, length(line)) ;
        (srcbuff+bufpos)^ := #10 ;
        inc(bufpos) ;

        inc(addrInt, wordsUsed*2) ;
      end else
        inc(addrInt, 2) ;
      end{ "while" } ;
  end{ "procedure Disas11" } ;

end{ "unit Pdp11DisasU" } .
