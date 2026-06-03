LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY flash IS
  PORT(
        -- Common
		  CLK					  : IN std_logic;
        DATAIN            : IN std_logic_vector(7 DOWNTO 0);
		  ADDR              : IN std_logic_vector(15 DOWNTO 0);
		  RD                : IN std_logic;
        WR                : IN std_logic;
		  FL_DI			 	  : IN std_logic;
		  DATAOUT           : OUT std_logic_vector(7 DOWNTO 0);
	  	  FL_SCK				  : OUT std_logic;
		  FL_CS				  : OUT std_logic;
		  FL_DO  	        : OUT std_logic);
   END flash;
	
ARCHITECTURE behavior OF flash IS


BEGIN


PROCESS (WR,ADDR)
BEGIN
	IF (rising_edge(WR) AND ADDR = x"0098") THEN
		FL_SCK <= DATAIN(0);
		FL_CS <= DATAIN(1);
		FL_DO <= DATAIN(2);
	END IF;
END PROCESS;


	
DATAOUT <= "0000000" & FL_DI WHEN ADDR = x"0098" ELSE "ZZZZZZZZ";	

	
END;	
	
