LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY clkgen IS
  PORT(
        -- Common
        CLK                : IN std_logic;
        RESET              : IN std_logic;
        RST_OUT            : OUT std_logic);
	  		  	
   END clkgen;
	
ARCHITECTURE behavior OF clkgen IS

SIGNAL CNT : INTEGER RANGE 0 TO 16 := 0;

BEGIN
	PROCESS (RESET,CLK)
	BEGIN
		IF (rising_edge(CLK)) THEN
			IF (RESET = '0') THEN
				CNT <= 0;
				RST_OUT <= '1';
			ELSIF (CNT < 10) THEN
				RST_OUT <= '1';
				CNT <= CNT + 1;
			ELSE
				RST_OUT <= '0';
			END IF;
		END IF;
	END PROCESS;
END;	
	
