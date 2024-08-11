ACCOUNT := p86850054

# nuumber of processors on a node (36 maxfor both casper and cheyenne, 128 for Derecho)
ppn    ?= 37

# number of 'steps' to peform, assume the number of input args
nsteps := $(shell cat ./inputs.txt | grep -v '\#' | wc -l)

# number of PBS job array 'jobs' to perform.  Each job will execute up to ppn step.
njobs  := $(shell echo $$(($(nsteps)/$(ppn)-1)))

run:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	@echo "compiler=$(comp)"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y -v comp=$(comp) test_tracer.pbs

solo single:
	@echo "account=$(ACCOUNT)"
	@echo "arguments=$(args)"
	qsub -A $(ACCOUNT) -q develop -J 0-1 -l select=1:ncpus=1:mpiprocs=1:mem=200G -r y -v args="$(args)" test_solo.pbs


ifort intel:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	@echo "compiler=intel"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y -v comp="intel" test_tracer.pbs

gfortran gcc:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	@echo "compiler=gcc"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y -v comp="gcc" test_tracer.pbs
