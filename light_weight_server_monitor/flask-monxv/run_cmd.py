# from: https://github.com/fabianlee/blogcode/blob/master/python/runProcessWithLiveOutput.py

import sys
import subprocess

# initial outline from: https://github.com/fabianlee/blogcode/blob/master/python/runProcessWithLiveOutput.py
# Idea is to have a long running (some minutes) script return each line of progress as it is emitted.
# Ideal Python feature is not 'return' but yield that slickly resumes thereafter at next function call :-)
# This permits a caller like:
#   for r in run_cmd(xyz): process(r)

def run_cmd(command):
	try:
		process = subprocess.Popen(command, shell=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
	except:
		# print("ERROR {} while running {}".format(sys.exc_info()[1], command))
		str = "ERROR: %s while running: %s" % (sys.exc_info()[1], command)
		print(str)
		return(str)
	output = process.stdout.readline().rstrip()			# remove RHS whitespace including newline(s)
	while len(output) > 0:
		yield output
		output = process.stdout.readline().rstrip()


#def run_cmd3(command, shellType=False, stdoutType=subprocess.PIPE):
#	yield "ERROR: /Users/robnav/github/controllertools/light_weight_server_monitor/dataconv/load_all.sh (f=main,l=322) failed: no valid -d directories"
#	yield "Usage: load_all.sh -d <data dir1>,<d2>,<d3> 	# load all monitor data therein - comma separated directories"
#	yield "[-e]						# empty openTSDB of data for test1.1m.avg"
#	yield "[-m	<mon1>,<mon2>]				# chosen monitors to load - comma separated"
#	yield "[-c	<dataconv directory>]			# where the conversion tools live"
