;----------------------------------------------------------------------------
     ;DOS (C)Copyright 1988-1989 Microsoft
     ;Gelicentieerd materiaal- Eigendom van Microsoft
;----------------------------------------------------------------------------
PRINTER GRAPHICS,THERMAL    ;; 5152, 4201, 4202(8"), 5201-002(8"), 5202, 3812
			    ;; 4207, 4208, 5140

   ; Maximale afdrukbreedte: 8"
   ; Horizontale BPI: 120    Verticale BPI: 72
   ; SETUP Opdrachten bevatten de volgende Escape-codes:
   ;   27,51,24 = instelling regelafstand op 24/216
   ; GRAPHICS Opdrachten gebruiken ESC "L" - de laatste twee bytes
   ; vertegenwoordigen getelde gegevens (laag,hoog)

  DISPLAYMODE 4,5,13,19     ;; 320x200 > 6.7"x8.9" gedraaid
    SETup 27,51,24
    GRAPHICS 32,32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,2,ROTATE
    PRINTBOX LCD,2,2,ROTATE

  DISPLAYMODE 6,14	   ;; 640x200 > 6.7"x8.9" gedraaid
    SETup 27,51,24
    GRAPHICS 32,32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,1,ROTATE
    PRINTBOX LCD,2,1,ROTATE

  DISPLAYMODE 15,16	   ;; 640x350 > 5.8"x8.9" gedraaid
    SETup 27,51,24
    GRAPHICS 32,32,32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,2,1,ROTATE
    PRINTBOX LCD	     ;; PC/Convertible ondersteunt deze modi niet

  DISPLAYMODE 17,18	   ;; 640x480 > 8"x8.9" gedraaid
    SETup 27,51,24
    GRAPHICS 27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,2,1,ROTATE
    PRINTBOX LCD	     ;; PC/Convertible ondersteunt deze modi niet


;---------------------------------------------------------------------------
PRINTER COLOR8		     ;; 5182 CMY Ribbon

   ; Maximale afdrukbreedte: 8"
   ; Horizontale BPI: 168 bij verhouding 1:1, 140 bij verhouding 5:6
   ; Verticale BPI: 84
   ; SETUP Opdrachten bevatten de volgende Escape-codes:
   ;   27,51,14 = instelling regelafstand op 14/144
   ;   27,110,[0|1] = 0 voor verhouding 5:6, 1 voor verhouding 1:1
   ; GRAPHICS Opdrachten gebruiken ESC "L" - de laatste twee bytes
   ; vertegenwoordigen getelde gegevens (laag,hoog)

  COLORSELECT Y,27,121	     ;; geel lint
  COLORSELECT M,27,109	     ;; magenta lint
  COLORSELECT C,27,99	     ;; lichtblauw lint
  COLORSELECT B,27,98	     ;; zwart lint
			     ;;
			     ;; Onderstaande RGB's vertegenwoordigen
			     ;; de eerste 16 schermkleuren.
			     ;; SCHERMKLEUR 	   AFDRUKKLEUR
			     ;; ------------	   -----------
  COLORPRINT 0,0,0,B	     ;; ZWART		   ZWART
  COLORPRINT 0,0,42,C	     ;; BLAUW		   LICHTBLAUW
  COLORPRINT 0,42,0,Y,C      ;; GROEN		   GROEN
  COLORPRINT 0,42,42,C	     ;; LICHTBLAUW		   LICHTBLAUW
  COLORPRINT 42,0,0,Y,M      ;; ROOD		   ROOD
  COLORPRINT 42,0,42,C,M     ;; PAARS		   PAARS
  COLORPRINT 42,21,0,Y,C,M   ;; BRUIN		   BRUIN
  COLORPRINT 42,42,42	     ;; WIT	   WIT (NIETS)
  COLORPRINT 21,21,21,B      ;; GRIJS		   ZWART
  COLORPRINT 21,21,63,C      ;; FEL BLAUW	   LICHTBLAUW
  COLORPRINT 21,63,21,Y,C    ;; FEL GROEN	   GROEN
  COLORPRINT 21,63,63,C      ;; FEL LICHTBLAUW	   LICHTBLAUW
  COLORPRINT 63,21,21,Y,M    ;; FEL ROOD	   ROOD
  COLORPRINT 63,21,63,M      ;; MAGENTA 	   MAGENTA
  COLORPRINT 63,63,21,Y      ;; GEEL		   GEEL
  COLORPRINT 63,63,63	     ;; FEL WIT	   WIT (NIETS)

  COLORPRINT 42,42,0,Y	     ;; Deze opdracht maakt van "geel" in het
			     ;;  CGA palet 0 geel
			     ;;
  DISPLAYMODE 4,5,13,19       ;; 320x200
    SETUP 27,51,14,27,110,0   ;; verhouding = 5:6
    GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,2,ROTATE
  DISPLAYMODE 6,14	      ;; 640x200
     SETUP 27,51,14,27,110,0  ;; verhouding = 5:6
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,4,1,ROTATE
  DISPLAYMODE 15,16	      ;; 640x350
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,3,1,ROTATE
  DISPLAYMODE 17,18	      ;; 640x480
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,2,1

;---------------------------------------------------------------------------
PRINTER COLOR4		     ;; 5182 RGB Ribbon

   ; Maximale Afdrukbreedte: 8"
   ; Horizontale BPI: 168 in 1:1 verhouding, 140 in 5:6 verhouding
   ; Verticale BPI: 84
   ; SETUP Opdrachten bevatten de volgende Escape-codes:
   ;   27,51,14 = instelling regelafstand in 14/144
   ;   27,110,[0|1] = 0 voor verhouding 5:6, 1 voor verhouding 1:1
   ; GRAPHICS Opdrachten gebruiken ESC "L" - de laatste twee bytes
   ; vertegenwoordigen getelde gegevens (laag,hoog)

  COLORSELECT R,27,121	     ;; rood lint
  COLORSELECT G,27,109	     ;; groen lint
  COLORSELECT B,27,99	     ;; blauw lint
  COLORSELECT X,27,98	     ;; zwart lint
			     ;;
			     ;; Onderstaande RGB's vertegenwoordigen
			     ;; de eerste 16 schermkleuren.
			     ;; SCHERMKLEUR 	   AFDRUKKLEUR
			     ;; ------------	   -----------
  COLORPRINT 0,0,0,X	     ;; ZWART		   ZWART
  COLORPRINT 0,0,42,B	     ;; BLAUW		   BLAUW
  COLORPRINT 0,42,0,G	     ;; GROEN		   GROEN
  COLORPRINT 0,42,42,B	     ;; LICHTBLAUW		   BLAUW
  COLORPRINT 42,0,0,R	     ;; ROOD		   ROOD
  COLORPRINT 42,0,42,R	     ;; PAARS		   ROOD
  COLORPRINT 42,21,0,X	     ;; BRUIN		   ZWART
  COLORPRINT 42,42,42	     ;; WIT	   WIT (NIETS)
  COLORPRINT 21,21,21,X      ;; GRIJS		   ZWART
  COLORPRINT 21,21,63,B      ;; FEL BLAUW	   BLAUW
  COLORPRINT 21,63,21,G      ;; FEL GROEN	   GROEN
  COLORPRINT 21,63,63,B      ;; FEL LICHTBLAUW	   BLAUW
  COLORPRINT 63,21,21,R      ;; FEL ROOD	   ROOD
  COLORPRINT 63,21,63,R      ;; MAGENTA 	   ROOD
  COLORPRINT 63,63,21	     ;; GEEL		   WIT (NIETS)
  COLORPRINT 63,63,63	     ;; FEL WIT	   WIT (NIETS)

  COLORPRINT 42,42,0,B	     ;; Deze opdracht maakt van "geel" in het CGA
			     ;;  palet 0 blauw , zoals gebeurde in versies van GRAPHICS
			     ;;
  DISPLAYMODE 4,5,13,19       ;; 320x200
    SETUP 27,51,14,27,110,0   ;; verhouding = 5:6
    GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,2,ROTATE
  DISPLAYMODE 6,14	      ;; 640x200
     SETUP 27,51,14,27,110,0  ;; verhouding = 5:6
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,4,1,ROTATE
  DISPLAYMODE 15,16	      ;; 640x350
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,3,1,ROTATE
  DISPLAYMODE 17,18	      ;; 640x480
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,2,1

;---------------------------------------------------------------------------
PRINTER GRAPHICSWIDE   ;; 4202(13.5"), 5201-002(13.5")

   ; Maximale Afdrukbreedte: 13.5"
   ; Horizontale BPI: 120    Verticale BPI: 72
   ; SETUP Opdrachten bevatten de volgende Escape-codes:
   ;   27,88,1,255 = instelling afdrukken op 13.5"
   ;   27,51,24 = instelling regelafstand in 24/216
   ;   27,51,18 = instelling regelafstand in 18/216 (UITSLUITEND 320x200 MODI!!)
   ; GRAPHICS Opdrachten gebruiken ESC "L" - de laatste twee bytes
   ; vertegenwoordigen getelde gegevens (laag,hoog)

  DISPLAYMODE 4,5,13,19     ;; 320x200	> 10.7"x8.3" niet gedraaid
    SETup 27,88,1,255,27,51,18
    GRAPHICS 27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,3

  DISPLAYMODE 6,14	    ;; 640x200 - als voor afdrukken op 8"
    SETup 27,88,1,255,27,51,24
    GRAPHICS 27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,1,ROTATE

  DISPLAYMODE 15,16	    ;; 640x350 > 11.7"x17.8" gedraaid
    SETup 27,88,1,255,27,51,24
    GRAPHICS 27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,2,ROTATE

  DISPLAYMODE 17,18	    ;; 640x480 > 12"x17.8" gedraaid
    SETup 27,88,1,255,27,51,24
    GRAPHICS 27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,3,2,ROTATE

;---------------------------------------------------------------------------
PRINTER COLOR1		       ;; 5182 met zwart lint

   ; Maximale Afdrukbreedte: 8"
   ; Horizontale BPI: 168 bij verhouding 1:1, 140 bij verhouding 5:6
   ; Verticale BPI: 84
   ; SETUP Opdrachten bevatten de volgende Escape-codes:
   ;   27,51,14 = instelling regelafstand in 14/144
   ;   27,110,[0|1] = 0 voor verhouding to 5:6, 1 voor verhouding 1:1
   ; GRAPHICS Opdrachten gebruiken ESC "L" - de laatste twee bytes
   ; vertegenwoordigen getelde gegevens (laag,hoog)

  DARKADJUST 0		      ; Geef een positief getaal voor lichtere
			      ;  afdruk. Voorgestelde waarde = 10

  DISPLAYMODE 4,5,13,19       ;; 320x200
    SETUP 27,51,14,27,110,0   ;; verhouding = 5:6
    GRAPHICS 32,32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,2,ROTATE
    PRINTBOX LCD,2,2,ROTATE

  DISPLAYMODE 6,14	      ;; 640x200
    SETUP 27,51,14,27,110,0  ;; verhouding = 5:6
    GRAPHICS 32,32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
    PRINTBOX STD,4,1,ROTATE
    PRINTBOX LCD,2,1,ROTATE

  DISPLAYMODE 15,16	      ;; 640x350
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,3,1,ROTATE
     PRINTBOX LCD	      ;; PC/Convertible ondersteunt deze modi niet

  DISPLAYMODE 17,18	      ;; 640x480
     SETUP 27,51,14,27,110,1  ;; verhouding = 1:1
     GRAPHICS 32,32,32,32,27,76,LOWCOUNT,HIGHCOUNT
     PRINTBOX STD,2,1
     PRINTBOX LCD	      ;; PC/Convertible ondersteunt deze modi niet


;===========================================================================
;			    End of Profile
;===========================================================================
