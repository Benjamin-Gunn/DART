
C        SUBROUTINE FORIT
C
C        PURPOSE

C           FOURIER ANALYSIS OF A PERIODICALLY TABULATED FUNCTION.
C           COMPUTES THE COEFFICIENTS OF THE DESIRED NUMBER OF TERMS
C           IN THE FOURIER SERIES F(X)=A(0)+SUM(A(K)COS KX+B(K)SIN KX)
C           WHERE K=1,2,...,M TO APPROXIMATE A GIVEN SET OF
C           PERIODICALLY TABULATED VALUES OF A FUNCTION.
C
C        USAGE
C           CALL FORIT(FNT,N,M,A,B,IER)
C
C        DESCRIPTION OF PARAMETERS
C           FNT-VECTOR OF TABULATED FUNCTION VALUES OF LENGTH 2N+1
C           N  -DEFINES THE INTERVAL SUCH THAT 2N+1 POINTS ARE TAKEN
C               OVER THE INTERVAL (0,2PI). THE SPACING IS THUS 2PI/2N+1
C           M  -MAXIMUM ORDER OF HARMONICS TO BE FITTED
C           A  -RESULTANT VECTOR OF FOURIER COSINE COEFFICIENTS OF
C               LENGTH M+1
C               A SUB 0, A SUB 1,..., A SUB M
C           B  -RESULTANT VECTOR OF FOURIER SINE COEFFICIENTS OF
C               LENGTH M+1
C               B SUB 0, B SUB 1,..., B SUB M
C           IER-RESULTANT ERROR CODE WHERE
C               IER=0  NO ERROR
C               IER=1  N NOT GREATER OR EQUAL TO M
C               IER=2  M LESS THAN 0
C
C        REMARKS
C           M MUST BE GREATER THAN OR EQUAL TO ZERO
C           N MUST BE GREATER THAN OR EQUAL TO M
C           THE FIRST ELEMENT OF VECTOR B IS ZERO IN ALL CASES
C
C        SUBROUTINES AND FUNCTION SUBPROGRAMS REQUIRED
C           NONE
C
C        METHOD
C           USES RECURSIVE TECHNIQUE DESCRIBED IN A. RALSTON, H. WILF,
C           "MATHEMATICAL METHODS FOR DIGITAL COMPUTERS", JOHN WILEY
C           AND SONS, NEW YORK, 1960, CHAPTER 24. THE METHOD OF INDEXING
C           THROUGH THE PROCEDURE HAS BEEN MODIFIED TO SIMPLIFY THE
C           COMPUTATION.
C

C     ..................................................................
C
      SUBROUTINE FORIT(FNT,N,M,A,B,IER)
      DIMENSION A(*),B(*),FNT(*)
C
C        CHECK FOR PARAMETER ERRORS
C
      IER=0
   20 IF(M) 30,40,40
   30 IER=2
      RETURN
   40 IF(M-N) 60,60,50
   50 IER=1
      RETURN
C
C        COMPUTE AND PRESET CONSTANTS
C
   60 AN=N
      COEF=2.0/(2.0*AN+1.0)
      CONST=3.141593*COEF
      S1=SIN(CONST)
      C1=COS(CONST)
      C=1.0
      S=0.0
      J=1
      FNTZ=FNT(1)
   70 U2=0.0
      U1=0.0
      I=2*N+1
C
C        FORM FOURIER COEFFICIENTS RECURSIVELY
C
   75 U0=FNT(I)+2.0*C*U1-U2
      U2=U1
      U1=U0
      I=I-1
      IF(I-1) 80,80,75
   80 A(J)=COEF*(FNTZ+C*U1-U2)
      B(J)=COEF*S*U1
      IF(J-(M+1)) 90,100,100

   90 Q=C1*C-S1*S
      S=C1*S+S1*C
      C=Q
      J=J+1
      GO TO 70
  100 A(1)=A(1)*0.5
      RETURN
      END