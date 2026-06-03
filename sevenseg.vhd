LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY sevenseg IS
  PORT(
        -- Common
        DATA              : IN std_logic_vector(7 DOWNTO 0);
		  ADDR              : IN std_logic_vector(15 DOWNTO 0);
        WR                : IN std_logic;
        SEG_A	           : OUT std_logic;
		  SEG_B	           : OUT std_logic;
        SEG_C	           : OUT std_logic;
        SEG_D	           : OUT std_logic;
        SEG_E	           : OUT std_logic;
        SEG_F	           : OUT std_logic;
        SEG_G	           : OUT std_logic);
	  		  	
   END sevenseg;
	
ARCHITECTURE behavior OF sevenseg IS

SIGNAL SEG : STD_LOGIC_VECTOR(6 DOWNTO 0);

BEGIN

	PROCESS (WR,ADDR)
	BEGIN
		IF (rising_edge(WR) AND ADDR = x"0080") THEN
		CASE DATA(3 DOWNTO 0) IS
			WHEN "0000" => SEG <= "1111110";
			WHEN "0001" => SEG <= "0110000";
			WHEN "0010" => SEG <= "1101101";
			WHEN "0011" => SEG <= "1111001";
			WHEN "0100" => SEG <= "0110011";
			WHEN "0101" => SEG <= "1011011";
			WHEN "0110" => SEG <= "1011111";
			WHEN "0111" => SEG <= "1110000";
			WHEN "1000" => SEG <= "1111111";
			WHEN "1001" => SEG <= "1111011";
			WHEN "1010" => SEG <= "1110111";
			WHEN "1011" => SEG <= "0011111";
			WHEN "1100" => SEG <= "1001110";
			WHEN "1101" => SEG <= "0111101";
			WHEN "1110" => SEG <= "1001111";
			WHEN "1111" => SEG <= "1000111";
		END CASE;
		END IF;
	END PROCESS;
	
	SEG_A <= SEG(6);
	SEG_B <= SEG(5);
	SEG_C <= SEG(4);
	SEG_D <= SEG(3);
	SEG_E <= SEG(2);
	SEG_F <= SEG(1);
	SEG_G <= SEG(0);
	
END;	
	
