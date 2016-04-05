
      FUNCTION TVARF2(RLTM,RLGM,DIP,R,PHI,TMO,DEC,PI,CLTM,SLTM)
      ALTM=ABS(RLTM)
      ATMO=TMO*PI/6.
      SEMI=SEMIAN(ATMO)
      REQ=1.-.2*R+.6*SQRT(R)
      SD=ZETA(DEC,RLTM)
      X=(2.2+(.2+.1*R)*SLTM)*CLTM
      FF=EXP(-X**6)
      GG=1.-FF
      CPD=COS(PHI-.873)
      EF=COS(PHI+PI/4.)
      EMF=EF*EF
      ADIUR=(.9+.32*SD)*(1.+SD*EMF)
      BQ=COS(ALTM-.2618)
      AQE=CLTM**8
      AQT=AQE*CLTM*CLTM
      AEQ=AQE*REQ*EXP(.25*(1.-CPD))
      EQ=(1.-.4*AQT)*(1.+AEQ*BQ**12)*(1.+.6*AQT*EMF)
      VEQ=EQ*(1.+.05*SEMI)
      VDIUR=ADIUR*EXP(-1.1*(CPD+1.))
      VLT=(EXP(3.*COS(RLTM*(SIN(PHI)-1.)/2.)))*(1.2-.5*CLTM*CLTM)
      VLT=VLT*(1.+.05*R*COS(ATMO)*SLTM**3)
      RTL=SQRT((12.*RLTM+4.*PI/3.)**2+(TMO/2.-3.)**2)
      VLAT=VLT*(1.-.15*EXP(-RTL))
      RF=1.+R+(.204+.03*R)*R*R
      IF(R-1.1) 1,1,2
 2    CQ=1.53*SLTM*SLTM
      RF=2.39+CQ*(RF-2.39)
 1    CONTINUE
      VUT=YONII(RLTM,RF,R,PHI,TMO,DEC,PI,CLTM,SLTM)
      POLER=POLAR(RLTM,RLGM,DIP,R,PHI,TMO,DEC,PI,CLTM,SLTM)
      SHIFT=7.*PI/18.
      VLONG=1.+.1*(CLTM**3)*COS(2.*(RLGM-SHIFT))
      ADIP=ABS(DIP)
      DP=.15-.5*(1.+R)*(1.-CLTM)*EXP(-.33*(TMO-6.)**2)
      VDP=1.+DP*EXP(-18.*(ADIP-40.*PI/180.)**2)
      VDIP=VDP*(1.+.03*SEMI)
      F2=VDIUR*VLAT*VUT*VEQ*RF*VLONG*VDIP
      TVARF2=FF*POLER+GG*F2
      RETURN
      END