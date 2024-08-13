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
	@bash ./test_setup.sh $(comp)
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y test_tracer.pbs

solo single: 
	@echo "account=$(ACCOUNT)"
	@echo "arguments=$(args)"
	@qsub -A $(ACCOUNT) -q develop -l select=1:ncpus=1:mpiprocs=1:mem=200G -r y -v args="$(args)" test_solo.sh

ifort intel:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	@echo "compiler=iFort"
	@bash ./test_setup.sh "intel"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y test_tracer.pbs

gfortran gcc:
	@echo "account=$(ACCOUNT)"
	@echo "ppn=$(ppn)"
	@echo "nsteps=$(nsteps)"
	@echo "njobs=$$(($(njobs)+1)) / $$(($$(($(njobs)+1)) * $(ppn)))"
	@echo "compiler=GFortran"
	@bash ./test_setup.sh "gcc"
	qsub -A $(ACCOUNT) -q main -J 0-$(njobs) -l select=1:ncpus=$(ppn):mpiprocs=$(ppn):mem=200G -r y test_tracer.pbs

help options: 
	@echo ' Tracer Filter Test Options...'
	@echo ''
	@echo ' "make run":'
	@echo '  • Runs all fiter tests from inputs.txt with job arrays.'
	@echo '  • Defaul compiler is GFortran, but can be selected by'
	@echo '    running make run comp="compiler"'
	@echo ''
	@echo ' "make intel" / "make ifort":'
	@echo '  • Runs all fiter tests from inputs.txt with job arrays.'
	@echo '  • Compiler is ifort.'
	@echo ''
	@echo ' "make gcc" / "make gfortran":'
	@echo '  • Runs all fiter tests from inputs.txt with job arrays.'
	@echo '  • Compiler is GFortran.'
	@echo ''
	@echo ' "make solo" / "make single":'
	@echo '  • Runs only one filter test based on user input.'
	@echo '  • Input can be entered with the syntax:'
	@echo '    make solo args="arguments"'
	@echo '  • Enter arguments in a string with spaces between values:'
	@echo '    "CSV_File" Ensemble_Size PE_Count positive_tracer bounded_above post_inf_flavor compiler'
	@echo ''