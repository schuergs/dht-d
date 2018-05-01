/**
 * dht_example: Example code wrapper for dht-d boot server
 *
 * Copyright (c) 2016 Stefan Schuerger
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */

module dhtbootserver_example;

import std.socket;
import std.stdio;
import std.conv;
import std.random;
import std.getopt;
import std.array;
import std.string;
import std.file;
import std.algorithm;
import std.experimental.logger;
import core.stdc.time;
import core.stdc.signal;
import core.sys.posix.signal; // For SIGUSR1 / SIGUSR2
import core.sys.posix.netinet.in_;

import dht;
import dhtbootserver;

static string nodes_filename = "nodes_bs.sav";

int main(string[] args){
    bool quiet = false;
    bool ipv4wanted = false;
    bool ipv6wanted = false;
    bool verbose    = false;
    bool do_search  = false;
    bool do_boot_search = false;
    ushort search_interval_default = 15;
    ushort search_interval = search_interval_default;
    ushort print_buckets_default = 60;
    ushort print_buckets = print_buckets_default;
    ushort myport;
    
    static bool flag_search  = false,
                flag_buckets = false,
		flag_exit    = false;
    
    signal(SIGINT, (dummy){flag_exit = true; });
    signal(SIGTERM,(dummy){flag_exit = true; });
    signal(SIGHUP, (dummy){flag_exit = true; });
    signal(SIGUSR1,(dummy){flag_buckets = true; });
    signal(SIGUSR2,(dummy){flag_search = true; });
    
    auto helpInformation = getopt(
    args,
    std.getopt.config.caseSensitive,
    std.getopt.config.bundling,
    std.getopt.config.passThrough,
    "ipv4|4",          "Use IPv4.",         &ipv4wanted,
    "ipv6|6",          "Use IPv6.",         &ipv6wanted,
    "search|s",        "Perform random searches.", &do_search,
    "search-interval", "Search interval (default: " ~ to!string(search_interval_default) ~ " seconds).", &search_interval,
    "bucket-interval|B", "Time between bucket displays (0=off, default: " ~ to!string(print_buckets_default) ~ " seconds).", &print_buckets,
    "boot-search|b",   "Perform a boot search at start.", &do_boot_search,
    "quiet|q",         "Only show warnings and above.",    &quiet,
    "verbose|v",       "Show trace information.",  &verbose,   // flag
    );  

    args = args[1..$]; // remove command
   
    if (helpInformation.helpWanted || args.length < 1 || (args.length & 1) != 1){
        args_broken:
        defaultGetoptPrinter("dht_example [-4|-6] -sbqv port boot_ip boot_port [boot_ip boot_port]...",
        helpInformation.options);
	return 1;
    }    

    try myport = to!ushort(args[0]);
    catch(Exception e){
	    stderr.writeln("Invalid port: ", args[0]);
	    return 99;
    }	    
	    
    
    args = args[1..$];
    
    if(!ipv4wanted && !ipv6wanted)    
        ipv4wanted = ipv6wanted = true;

    fLog = new FileLogger(stdout);

    /*
    if(quiet)
        globalLogLevel = LogLevel.warning;
    else if(verbose)
        globalLogLevel = LogLevel.all;
    else
        globalLogLevel = LogLevel.info;*/
       
    DHTId my_id = DHTId.random;
    
    Socket s=null,s6=null;	
    if(ipv4wanted){
        s  = new Socket(AddressFamily.INET,SocketType.DGRAM);
        s.blocking  = false;
        s.bind(new InternetAddress(myport));
    }
    if(ipv6wanted){
        s6 = new Socket(AddressFamily.INET6,SocketType.DGRAM);
        s6.blocking = false;
        s6.setOption(SocketOptionLevel.IPV6,SocketOption.IPV6_V6ONLY,1);
        s6.bind(new Internet6Address(myport));
    }
    
    DHTBootserver dht = new DHTBootserver(my_id,s,s6);
    fLog.info("My ID: " ~ my_id.toString);

    if(exists(nodes_filename) && isFile(nodes_filename))
        load(dht,nodes_filename);
    else if(args.length < 2)
        goto args_broken;
    
    while(args.length > 0){
        Address target;
        try target = getAddress(args[0],to!ushort(args[1]))[0].to_subtype();
	catch(Exception e){
	    stderr.writeln("'",args[0],"' + '", args[1],"' is not a valid address/port combination");
	    return 99;
	}
	if(target.addressFamily != AddressFamily.INET && target.addressFamily != AddressFamily.INET6){
	    stderr.writeln("'",args[0],"' + '", args[1],"' is not a valid IPv4/IPv6 address");
	    return 99;
	}
	if(target.addressFamily == AddressFamily.INET && !ipv4wanted){
	    stderr.writeln("-6 specified, but IPv4 boot address given: ",target);
	    return 99;
	}
	if(target.addressFamily == AddressFamily.INET6 && !ipv6wanted){
	    stderr.writeln("-4 specified, but IPv6 boot address given: ",target);
	    return 99;
	}
	dht.boot(target);
	args = args[2..$];
    }
    if(do_boot_search)
        dht.boot_search();

    time_t search_start   = dht.now + 10;
    time_t next_search = 0;
    time_t lastshow = 0;

    time_t nextrun = 1;
    while(1){
        SocketSet ss=new SocketSet;
        if(s !is null) ss.add(s);
        if(s6 !is null) ss.add(s6);
        
        TimeVal tv;
        tv.seconds = nextrun;    
        
        int rc = Socket.select(ss,null,null,&tv);
        
        if(rc>0){
	    Socket sx;
	    if(s !is null && ss.isSet(s)){
	        sx = s;
	    } else if (s6 !is null && ss.isSet(s6)){
	        sx = s6;
	    }
            Address sender;
        
            static ubyte[4096] bufx;
	    auto len = sx.receiveFrom(bufx,sender);

	    dht.periodic(bufx[0..len+1],sender,nextrun);
        } else {
            dht.periodic([],null,nextrun);
        }
	
	// Random searching
	if(flag_search || (do_search && dht.now > search_start)){
	    if(flag_search || dht.now >= next_search){
	        dht.new_search(DHTId.random);
	        next_search = dht.now + search_interval;
	    }
	    flag_search = false;
	}
        
        // Show buckets
	if(flag_buckets || (print_buckets > 0 && lastshow <= dht.now - print_buckets)){
            fLog.critical(dht);
	    lastshow = dht.now;
	    flag_buckets = false;
	    save(dht,nodes_filename);
	}
	
	if(flag_exit){
	    fLog.warning("SIGINT caught, exiting.");
	    break;	
	}
    } 

    save(dht,nodes_filename);
    
    return 0;
}

static void load(DHTBootserver dht,string fname){
    auto f = File(fname,"rb");
    
    dht.info.myid = DHTId(f.readln().chomp);
    dht.info6.myid = DHTId(f.readln().chomp);
    string idline, addressline, portline;
    while((idline = f.readln()) !is null){
    
        import core.sys.posix.arpa.inet;
    
        addressline = f.readln();
	if(addressline is null )
	    break;
        portline = f.readln();
	if(portline is null )
	    break;

	idline = idline.chomp;
        addressline = addressline.chomp;
	portline = portline.chomp;
	    
        fLog.trace("Loading ", idline, " ", addressline, ":", portline); stdout.flush;
	    
	DHTId id = DHTId(idline);
	Address address = parseAddress(addressline,to!ushort(portline));
        auto node = dht.insert_node(id,address);
	// Mark loaded node as mature
	node.first_seen = dht.now - dht.globals_bs.node_maturity_threshold;
    }
}

static void save(DHTBootserver dht, string fname){
    auto f = File(fname,"wb");
    
    f.writeln(dht.info.myid);
    f.writeln(dht.info6.myid);
    foreach(node; dht.get_nodes(DHT.want,9999,9999,(n){return n.is_mature;})){
        f.writeln(node.id);
        f.writeln(node.address.toAddrString());
        f.writeln(node.address.toPortString());
    }
}

