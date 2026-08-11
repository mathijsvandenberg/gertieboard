# busdecode

Source: [`busdecode.vhd`](../../busdecode.vhd) · Instance `busdecode1` · Clock `c0` (8.33 MHz)

The glue between the real CPU and everything else. It latches the multiplexed
address, generates the bus strobes, drives the READY handshake, arbitrates the
memory bus for DMA, and implements the boot ROM overlay and the DMA page register.

## Ports

### CPU side

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 8.33 MHz bus clock (`c0`) |
| `AD` | INOUT | 8 | Multiplexed address/data — connects straight to `CPU_AD` |
| `A` | IN | 12 | Address bits 19:8 (non-multiplexed) |
| `RD` | IN | 1 | CPU read strobe, active low |
| `WR` | IN | 1 | CPU write strobe, active low |
| `ALE` | IN | 1 | Address latch enable |
| `DEN` | IN | 1 | Data enable |
| `DTR` | IN | 1 | Data transmit/receive direction |
| `IOM` | IN | 1 | 1 = I/O cycle, 0 = memory cycle |
| `READY` | OUT | 1 | To `CPU_RDY` — inserts wait states |

### Peripheral side

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `DATA_IN` | IN | 8 | Read data from peripherals (`n_periph_rdata`) |
| `DATA_OUT` | OUT | 8 | Write data to peripherals (`n_cpu_wdata`) |
| `IO_ADDR` | OUT | 16 | Latched I/O address |
| `IO_RD` / `IO_WR` | OUT | 1 | I/O strobes, active low |
| `MEM_ADDR` | OUT | 20 | Latched memory address, or the DMA address during `HLDA` |
| `MEM_RD` / `MEM_WR` | OUT | 1 | Memory strobes, active low |
| `RAM_READY` | IN | 1 | From `mem_hybrid` — memory cycle complete |

### DMA arbitration

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `HLDA` | IN | 1 | CPU has released the bus |
| `DMA_ADDR` | IN | 16 | Current 8237 address |
| `DMA_MEMR` / `DMA_MEMW` | IN | 1 | DMA memory strobes, active low |
| `DMA_DOUT` | IN | 8 | Byte from the FDC heading to memory |

### Boot ROM overlay

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `ROM_EN` | IN | 1 | `'1'` = overlay active |
| `ROM_DATA` | IN | 8 | Boot ROM byte at `MEM_ADDR(9:0)` |

## Address latching

```vhdl
IF (ALE = '1' AND IOM = '0') THEN        -- memory cycle
    maddr_l  <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
    ioaddr_l <= x"FFFF";                 -- deliberately impossible
ELSIF (ALE = '1' AND IOM = '1') THEN     -- I/O cycle
    ioaddr_l <= A(15 DOWNTO 8) & AD(7 DOWNTO 0);
    maddr_l  <= x"FFFFF";
```

The unused bus is parked at an address nothing decodes, so a memory cycle can
never be mistaken for an I/O cycle by a peripheral watching only its own address.

## READY generation

```vhdl
READY <= '1' WHEN (T >= 64 AND MEMADDR AND IOM = '0')
    ELSE '1' WHEN (MEMADDR AND IOM = '0' AND RAM_READY = '1')
    ELSE '1' WHEN (T >= 3 AND (NOT MEMADDR OR IOM = '1'))
    ELSE '0';
```

`T` counts CPU clocks since `ALE`. Memory cycles are governed by `RAM_READY`; I/O
completes after 3 clocks.

> ⚠️ **The `T >= 128` clause is a fault backstop, not a timing parameter.** It must
> stay longer than the slowest legitimate access. It was originally `T >= 10`, which
> aborted every PSRAM cache-line fill and released the CPU before the data bus was
> driven — silent corruption on every miss.
>
> It is **128** clocks, which is **15.4 µs** at the 8.33 MHz `c0`. The count is in CPU
> clocks, so its *duration* shrinks as `c0` rises while the thing it guards does not:
> the PSRAM side runs on `c3` and did not get faster, so the deadline it must beat has
> not moved. It was 64 clocks at 5 MHz (12.8 µs) and was doubled when the bus clock was
> raised, precisely so the margin did not quietly evaporate.
>
> This is the dangerous class of constant. Nothing breaks visibly when it is missed — a
> backstop that fires early releases the CPU onto an undriven bus and returns rubbish,
> which does not look like a clock problem.

`MEMADDR` is `ADDR < 0xA0000` or `ADDR >= 0xE0000`.

## Data routing

```vhdl
DATA_OUT <= DMA_DOUT       WHEN HLDA = '1'                        -- FDC -> memory
       ELSE AD(7 DOWNTO 0) WHEN (DTR = '1' AND DEN = '0')         -- CPU write
       ELSE "00000000";

AD <= ROM_DATA WHEN (HLDA='0' AND DTR='0' AND DEN='0' AND in_overlay='1')
 ELSE DATA_IN  WHEN (HLDA='0' AND DTR='0' AND DEN='0')
 ELSE "ZZZZZZZZ";
```

The boot ROM wins over PSRAM within the overlay window; otherwise peripheral read
data goes back to the CPU, and the bus is released whenever the CPU is not reading.

## Boot ROM overlay window

```vhdl
in_overlay <= '1' WHEN (ROM_EN = '1' AND IOM = '0'
                        AND maddr_l(19 DOWNTO 10) = "1111111111") ELSE '0';
```

That is `0xFF800`–`0xFFFFF`, **2 KB, reads only**. Writes are unaffected and pass
through to PSRAM, which is exactly what lets the bootloader fill the BIOS image
underneath itself.

> Keep this window in step with the array size in [`bootrom`](bootrom.md). It was
> 256 bytes (`maddr_l(19:8) = 0xFFF`) until the loader needed room for the
> flash-fallback path.

## DMA page register — I/O `0x81`

The XT used a separate 74LS612 for the upper address bits; here it lives inside
`busdecode`:

```vhdl
IF (wr_prev='0' AND WR='1' AND IOM='1' AND ADDR(15 DOWNTO 0) = x"0081") THEN
    dma_page <= AD(3 DOWNTO 0);

MEM_ADDR <= (dma_page & DMA_ADDR) WHEN HLDA = '1' ELSE maddr_l;
```

Without it the BIOS's 20-bit buffer address would be truncated to 64 KB.

## Related

- [Architecture](../architecture.md) — bus cycles, DMA sequence
- [mem_hybrid](mem_hybrid.md) — the `RAM_READY` producer
- [bootrom](bootrom.md) — the other half of the overlay
