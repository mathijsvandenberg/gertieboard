LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;
use std.textio.all;
use ieee.std_logic_textio.all;

ENTITY BIOS IS
  PORT(
        -- Common
		  DATAIN            : IN std_logic_vector(7 DOWNTO 0);
		  ADDR				  : IN std_logic_vector(19 DOWNTO 0);
		  RD                : IN std_logic;
        WR                : IN std_logic;
        CLK					  : IN std_logic;
		  
        
        DATAOUT           : INOUT std_logic_vector(7 DOWNTO 0));
   END BIOS;
	
ARCHITECTURE behavior OF BIOS IS

	TYPE ROMDATA IS ARRAY (0 TO 255) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL ROM : ROMDATA := (
    x"B8",x"00",x"B8",x"8E",x"D0",x"BC",x"E8",x"03",x"50",x"B8",x"00",x"00",x"8E",x"D8",x"58",x"50",
    x"B8",x"00",x"B8",x"8E",x"C0",x"58",x"B0",x"D0",x"A2",x"08",x"00",x"B0",x"FF",x"A2",x"09",x"00",
    x"B0",x"00",x"A2",x"0A",x"00",x"B0",x"F0",x"A2",x"0B",x"00",x"B0",x"42",x"A2",x"00",x"30",x"B0",
    x"4C",x"A2",x"01",x"30",x"B0",x"41",x"A2",x"02",x"30",x"33",x"FF",x"33",x"F6",x"B0",x"20",x"BE",
    x"D0",x"07",x"4E",x"26",x"88",x"04",x"83",x"FE",x"00",x"75",x"F7",x"1E",x"0E",x"1F",x"BF",x"00",
    x"00",x"BE",x"67",x"FF",x"B9",x"19",x"00",x"FC",x"F2",x"A4",x"1F",x"BF",x"00",x"01",x"BE",x"00",
    x"01",x"BB",x"00",x"08",x"E9",x"19",x"00",x"47",x"45",x"52",x"54",x"49",x"45",x"42",x"4F",x"41",
    x"52",x"44",x"20",x"42",x"4F",x"4F",x"54",x"52",x"4F",x"4D",x"20",x"32",x"30",x"32",x"36",x"00",
    x"BA",x"80",x"00",x"B0",x"00",x"EE",x"04",x"30",x"26",x"A2",x"54",x"00",x"2C",x"30",x"8A",x"0E",
    x"00",x"30",x"8A",x"2E",x"01",x"30",x"8A",x"26",x"02",x"30",x"26",x"88",x"0E",x"50",x"00",x"26",
    x"88",x"2E",x"51",x"00",x"26",x"88",x"26",x"52",x"00",x"50",x"52",x"B0",x"43",x"BA",x"99",x"00",
    x"EE",x"5A",x"58",x"B9",x"10",x"27",x"49",x"83",x"F9",x"00",x"75",x"FA",x"FE",x"C0",x"3C",x"0A",
    x"74",x"BE",x"EB",x"C1",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",
    x"B0",x"0A",x"EE",x"1E",x"50",x"B8",x"00",x"90",x"8E",x"D8",x"58",x"E4",x"99",x"88",x"05",x"81",
    x"FF",x"FF",x"08",x"74",x"10",x"47",x"1F",x"CF",x"20",x"20",x"20",x"20",x"20",x"20",x"20",x"20",
    x"EA",x"00",x"FF",x"00",x"F0",x"EA",x"00",x"01",x"00",x"90",x"47",x"42",x"00",x"00",x"00",x"00");



    ATTRIBUTE ramstyle : STRING;
    ATTRIBUTE ramstyle OF ROM : SIGNAL IS "M9K";
	 
	 SIGNAL ROM_DOUT : std_logic_vector(7 DOWNTO 0);
    SIGNAL ROM_SEL  : std_logic;
	
BEGIN

--	DATAOUT <= ROM(conv_integer(ADDR(12 DOWNTO 0)))
--               WHEN RD = '0' AND ADDR > x"FDFFF" AND ADDR < x"FFFFF"
--               ELSE "ZZZZZZZZ";
--DATAOUT <= ROM(conv_integer(ADDR(12 DOWNTO 0)))
--           WHEN RD = '0' AND ADDR(19 DOWNTO 16) = x"F"
--           ELSE "ZZZZZZZZ";
			  
PROCESS (CLK) BEGIN
    IF rising_edge(CLK) THEN
        ROM_DOUT <= ROM(conv_integer(ADDR(12 DOWNTO 0)));
        IF (RD = '0' AND ADDR(19 DOWNTO 16) = x"F") THEN
            ROM_SEL <= '1';
        ELSE
            ROM_SEL <= '0';
        END IF;
    END IF;
END PROCESS;

    DATAOUT <= ROM_DOUT WHEN ROM_SEL = '1' ELSE "ZZZZZZZZ";
	
END;	
	
