ACCOUNT := p86850054

# nuumber of processors on a node (36 maxfor both casper and cheyenne, 128 for Derecho)
ppn    ?= 128

# number of 'steps' to peform, assume the number of input args
nsteps := $(shell cat ./inputs.txt | grep -v '\#' | wc -l)

# number of PBS job array 'jobs' to perform.  Each job will execute up to ppn step.
njobs  := $(shell echo $$(( $(nsteps)/$(ppn) )))



run:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y test_tracer.pbs
