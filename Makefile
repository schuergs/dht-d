#
# Makefile to create dht_example and dhtbootserver_example 
#
#
# Copyright (c) 2016-2018 Stefan Schuerger
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#

CFLAGS=-g -O -version=statistics   -O
LN=dmd
CC=dmd
# For ldc2, use:
#CFLAGS=-g -O -d-version=StdLoggerDisableTrace -d-version=statistics 
#LN=ldc2
#CC=ldc2
# For GDC, use:
#CFLAGS=-g -O3 -fversion=statistics
#LN=gdc
#CC=gdc

all: dht_example dhtbootserver_example

%.o: %.d
	$(CC) -c  $(CFLAGS) $<


dht_example: dht.o dht_example.o
	$(LN) $(CFLAGS) $^ -of$@

dhtbootserver_example: dhtbootserver.o dhtbootserver_example.o dht.o
	$(LN) $(CFLAGS) $^ -of$@

dht.o: dht.d

dht_example.o: dht_example.d

dhtbootserver.o: dhtbootserver.d dht.d

dhtbootserver_example.o: dhtbootserver_example.d dhtbootserver.d

clean:
	rm -f core dht_example dht.o dht_example.o dhtbootserver_example dhtbootserver.o dhtbootserver_example.o
