LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY serial IS
  PORT(
        -- Common
		  CLK					  : IN std_logic;
        DATAIN            : IN std_logic_vector(7 DOWNTO 0);
		  ADDR              : IN std_logic_vector(15 DOWNTO 0);
		  RD                : IN std_logic;
        WR                : IN std_logic;
		  UARTRX			 	  : IN std_logic;
        INT		           : OUT std_logic;
		  DATAOUT           : OUT std_logic_vector(7 DOWNTO 0);
	  	  DBG		           : OUT std_logic_vector(7 DOWNTO 0);
		  UARTTX				  : OUT std_logic);
	
   END serial;
	
ARCHITECTURE behavior OF serial IS

COMPONENT UART_RX
GENERIC (
 g_CLKS_PER_BIT : integer := 500 -- 512 for 9600, now 2000
 );
PORT(	i_Clk 		: IN STD_LOGIC;
		i_RX_Serial	: IN STD_LOGIC;
		o_RX_DV		: OUT STD_LOGIC;
		o_RX_Byte	: OUT STD_LOGIC_VECTOR(7 DOWNTO 0));
END COMPONENT;



COMPONENT UART_TX
  GENERIC (
    g_CLKS_PER_BIT : integer := 500  
    );
  PORT (
    i_Clk       : in  std_logic;
    i_TX_DV     : in  std_logic;
    i_TX_Byte   : in  std_logic_vector(7 downto 0);
    o_TX_Active : out std_logic;
    o_TX_Serial : out std_logic;
    o_TX_Done   : out std_logic
    );
END COMPONENT;

 
 
 

	SIGNAL DATA	: STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL DV : STD_LOGIC;
	
	SIGNAL DONE : STD_LOGIC;
	SIGNAL BUSY : STD_LOGIC;
	SIGNAL DVTX : STD_LOGIC;
	

BEGIN


	U1 : UART_RX port map(CLK,UARTRX,DV,DATA);
	U2 : UART_TX port map(CLK,DVTX,DATAIN,BUSY,UARTTX,DONE);
	
--	PROCESS (CLK)
--	BEGIN
--		IF (rising_edge(CLK)) THEN
--			IF (DV = '1'
--		END IF
--	END PROCESS;
	
	
	DVTX <= '1' WHEN (ADDR = x"0099" AND WR='0') ELSE '0';
	DATAOUT <= DATA WHEN ADDR = x"0099" ELSE "ZZZZZZZZ";
	DBG <= DATA WHEN ADDR = x"0099" ELSE "ZZZZZZZZ";
	INT <= NOT DV;
	--INT <= '1';
	
	
END;	
	
