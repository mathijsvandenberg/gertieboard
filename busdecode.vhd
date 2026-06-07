LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY busdecode IS
  PORT(
        -- Common
		  CLK				: IN std_logic;
        AD          : INOUT std_logic_vector(7 DOWNTO 0);
        A  	              : IN std_logic_vector(19 DOWNTO 8);
		  RD	              : IN std_logic;
        WR	           	  : IN std_logic;
        ALE		           : IN std_logic;
        DEN 	           : IN std_logic;
		  DTR 	           : IN std_logic;
		  IOM 	           : IN std_logic;
		  RAM_READY			  : IN std_logic;
	  
		  DATA_IN		: IN std_logic_vector(7 DOWNTO 0);
		  DATA_OUT		: OUT std_logic_vector(7 DOWNTO 0);
		  
		  IO_ADDR		: OUT std_logic_vector(15 DOWNTO 0);
		  IO_RD			: OUT std_logic;
		  IO_WR			: OUT std_logic;
		  MEM_ADDR		: OUT std_logic_vector(19 DOWNTO 0);
		  MEM_RD			: OUT std_logic;
		  MEM_WR			: OUT std_logic;
		  READY			: OUT std_logic);
		  
	  		  	
   END busdecode;
	
ARCHITECTURE behavior OF busdecode IS

SIGNAL T : INTEGER RANGE 0 TO 1023;
SIGNAL ADDR : STD_LOGIC_VECTOR(19 DOWNTO 0);
SIGNAL MEMADDR : boolean;
SIGNAL MEMADDR2 : boolean;

BEGIN


	PROCESS (CLK)
	BEGIN
	IF (rising_edge(CLK)) THEN
		IF (ALE = '1' AND IOM = '0') THEN
			T <= 1;
			IO_ADDR <= x"FFFF"; -- Bogus, make sure it does not match any logic address 
			MEM_ADDR <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
			ADDR <= A(19 DOWNTO 8) & AD(7 DOWNTO 0); 
		ELSIF (ALE = '1' AND IOM = '1') THEN
			T <= 1;
			IO_ADDR <= A(15 DOWNTO 8) & AD(7 DOWNTO 0);
			MEM_ADDR <= x"FFFFF";
			ADDR <= "0000" & A(15 DOWNTO 8) & AD(7 DOWNTO 0); 
		ELSE
			T <= T + 1;
		END IF;
	END IF;
	END PROCESS;
	
	DATA_OUT <= AD(7 DOWNTO 0) WHEN (DTR = '1' AND DEN='0') ELSE "00000000";
	AD <= DATA_IN WHEN (DTR = '0' AND DEN='0') ELSE "ZZZZZZZZ";
	IO_RD <=  NOT(NOT RD AND IOM);
	IO_WR <=  NOT(NOT WR AND IOM);
	
	MEM_RD <= NOT(NOT RD AND NOT IOM);
	MEM_WR <= NOT(NOT WR AND NOT IOM);
					
	READY <=  '1' WHEN (T >= 10 AND MEMADDR AND IOM = '0')
      ELSE '1' WHEN (MEMADDR AND IOM = '0' AND RAM_READY = '1')
      ELSE '1' WHEN (T >= 3 AND (NOT MEMADDR OR IOM = '1'))
      ELSE '0';
		
		
	--MEMADDR <= TRUE WHEN (ADDR > x"09FFF" AND ADDR < x"A0000") OR (ADDR > x"DFFFF" AND ADDR < x"F0000") ELSE FALSE;
	
	MEMADDR <= TRUE WHEN (ADDR < x"A0000")
                  OR (ADDR >= x"E0000" AND ADDR < x"F0000")
           ELSE FALSE;
			  
			  


END;	
	
