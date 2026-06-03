LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

-- int8259.vhd contains function logic of the Next186 Project
-- by Nicolae Dumitrache  (http://opencores.org/project,next186)
ENTITY int8259 IS
  PORT(
        -- Common
		  CLK					  : IN std_logic;
		  DATA				  : IN std_logic_vector(7 DOWNTO 0);
		  ADDR				  : IN std_logic_vector(15 DOWNTO 0);

		  RD					  : IN std_logic;
		  WR                : IN std_logic;
        INT0				  : IN std_logic;
		  INT1              : IN std_logic;
		  INTA              : IN std_logic;
		  DATAOUT			  : OUT std_logic_vector(7 DOWNTO 0);
		  INT           	  : OUT std_logic);

   END int8259;
	
ARCHITECTURE behavior OF int8259 IS

SIGNAL I : std_logic_vector(7 DOWNTO 0);
SIGNAL II : std_logic_vector(7 DOWNTO 0);
SIGNAL III : std_logic_vector(7 DOWNTO 0);

SIGNAL IRR: std_logic_vector(7 DOWNTO 0) := "00000000";
SIGNAL IMR: std_logic_vector(7 DOWNTO 0) := "00000000"; -- Mask Register
SIGNAL IV: std_logic_vector(7 DOWNTO 0);

SIGNAL INTR : std_logic;
BEGIN

-- COUNTER PROCESS
PROCESS (CLK)
BEGIN
	IF (rising_edge(CLK)) THEN
		II <= I;
		III <= II;
		IRR <= (IRR OR (NOT III AND II)) AND IMR;	-- Front Edge Detection
		
		IF (INTR = '0') THEN
			IF (IRR(0) = '1') THEN
				INTR <= '1';
				IV <= x"08";
				IRR(0) <= '0';
			ELSIF (IRR(1) = '1') THEN
				INTR <= '1';
				IV <= x"09";
				IRR(1) <= '0';
			END IF;
		ELSIF (INTA = '0') THEN
			INTR <= '0';
		END IF;
	
	END IF;		
END PROCESS;

-- REGISTER READ WRITE PROCESS
PROCESS (WR,ADDR)
BEGIN
	IF (rising_edge(WR)) THEN
		IF (ADDR = x"0020") THEN -- Set Mode register counter 0
			IMR <= DATA;
		END IF;
	END IF;
END PROCESS;

I <= "000000" & INT1 & INT0;
DATAOUT <= IV WHEN (INTA = '0') ELSE IMR WHEN ADDR = x"0020" ELSE "ZZZZZZZZ";
INT <= INTR;

END;	