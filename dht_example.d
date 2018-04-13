/**
 * dht_example: Example mini application using dht-d
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

module dht_example;

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

static string nodes_filename = "nodes.sav";
static string search_filename = "search.txt";


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
    
	// Signal handling: save nodes before exiting; 
	// USR1 triggers bucket status dump
	// USR2 triggers a search
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

    
    if(quiet)
        globalLogLevel = LogLevel.warning;
    else if(verbose)
        globalLogLevel = LogLevel.all;
    else
        globalLogLevel = LogLevel.info;
       
    DHTId my_id = DHTId(cast(ubyte[]) hexString!"21cb18b8297ad2517fb2ab4ee3b2c165c7b764a5");
    my_id = DHTId.random;
    
    
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
    
    DHT dht = new DHT(my_id,s,s6,(tp,id,ad){ 
	writeln("Callback for ", id, ": ",tp,"[",ad.length ,"]");
	writeln(ad.map!(to!string).array.join(", "));
    });
    fLog.info("My ID: " ~ my_id.toString);

    if(exists(nodes_filename) && isFile(nodes_filename))
        load(dht,nodes_filename);
    else if(args.length < 2)
        goto args_broken;
    
    while(args.length > 0){
        Address target;
        try target = getAddress(args[0],to!ushort(args[1]))[0];
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
	        dht.new_search(sample_info_hashes[uniform(0,sample_info_hashes.length)]);
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
	
        if(exists(search_filename) && isFile(search_filename))
            load_searches(dht,search_filename);
	
	
    } 

    save(dht,nodes_filename);
    
    return 0;
}

static void load(DHT dht,string fname){
    auto f = File(fname,"rb");
    
    dht.myid = DHTId(f.readln().chomp);
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
        dht.insert_node(id,address,true);
    }
}

static void save(DHT dht, string fname){
    auto f = File(fname,"wb");
    
    f.writeln(dht.myid);
    foreach(node; dht.get_nodes()){
        f.writeln(node.id);
        f.writeln(node.address.toAddrString());
        f.writeln(node.address.toPortString());
    }
}

static void load_searches(DHT dht,string fname){
    auto f = File(fname,"rb");
    
    string idline;
    while((idline = f.readln()) !is null){
	idline = idline.chomp;
	DHTId id = DHTId(idline);
	dht.new_search(id);
    }
    f.close();
    rename(fname,fname ~ ".done");
}




// Sample IDs to search for:
// Info hashes of Debian distro files
// fetched with 
//   wget http://bttracker.debian.org:6969/stat -O- \
//   | perl -ne 'print qq{\tDHTId(cast(ubyte[]) hexString!"$1"),\n} if /([0-9a-f]{40})/' | sort -u
// Here: filtered by grep amd64 | grep netinst
DHTId[] sample_info_hashes = [
	DHTId(cast(ubyte[]) hexString!"1670b2465b5f78f9fe385be2afd596e34cf1e477"),
	DHTId(cast(ubyte[]) hexString!"16c816c42f0c6730675b9969bb43144d4d660e3d"),
	DHTId(cast(ubyte[]) hexString!"19c234165421a2394859295327e5331186f3bd63"),
	DHTId(cast(ubyte[]) hexString!"1c60cbecf4c632edc7ab546623454b33a295ccea"),
	DHTId(cast(ubyte[]) hexString!"1ff33e08bc413e3da947cf10a2f42e047561692b"),
	DHTId(cast(ubyte[]) hexString!"203e072a19daee875867160053cb6fff37d8aa7c"),
	DHTId(cast(ubyte[]) hexString!"256228fcf4ad88a87f9fbb1efd43978c9d4bd1b8"),
	DHTId(cast(ubyte[]) hexString!"29397fe716cc6698bdaf6b813993b88e1ad7a86b"),
	DHTId(cast(ubyte[]) hexString!"2a02d618c56faf948cbd2abb09bbdf90845ce498"),
	DHTId(cast(ubyte[]) hexString!"2b41a32c76533a5571a46e65c8c1d58dfdf10863"),
	DHTId(cast(ubyte[]) hexString!"2c79686e9bb96835ee024fbfa04d74ac668aeae7"),
	DHTId(cast(ubyte[]) hexString!"30987c19cf0eae3cf47766f387c621fa78a58ab9"),
	DHTId(cast(ubyte[]) hexString!"31fcfc3d9b3a6ae4eb0b40a7ef6903c1c3510eec"),
	DHTId(cast(ubyte[]) hexString!"3727e176a8187e7e6855be546f442b8a999d516b"),
	DHTId(cast(ubyte[]) hexString!"37b6a5fa3af60b797d9ce49260dea24f5d2ecbc8"),
	DHTId(cast(ubyte[]) hexString!"3f601d7604e1fef13a8d2cea3c77513e9755fcd5"),
	DHTId(cast(ubyte[]) hexString!"3f87043453de9a8fccccb8db67f3d20b5ff20e92"),
	DHTId(cast(ubyte[]) hexString!"40d774417d6342a5d088504a7e98dc842c133b22"),
	DHTId(cast(ubyte[]) hexString!"4194e473d6c49630e1c6247d6716076809bb96ae"),
	DHTId(cast(ubyte[]) hexString!"44f1b8d27ccaca85344243bf7cecc1f45d66911d"),
	DHTId(cast(ubyte[]) hexString!"462f06b20a1160191a08f4fbc2e46449193ded35"),
	DHTId(cast(ubyte[]) hexString!"46d16f15a3122d17bda40de1f7110f7a899cef7a"),
	DHTId(cast(ubyte[]) hexString!"47b9ad52c009f3bd562ffc6da40e5c55d3fb47f3"),
	DHTId(cast(ubyte[]) hexString!"4cf2fa5b27cbad86ac42777bb3e2d0cdcf45ff69"),
	DHTId(cast(ubyte[]) hexString!"4f4d92cd839e6d475daadeba79ff56adb884c1c6"),
	DHTId(cast(ubyte[]) hexString!"51273f52eb85bbd1318faa053e9091faa4fa1f51"),
	DHTId(cast(ubyte[]) hexString!"5471f01f3814173869ef88f24056191ccd935396"),
	DHTId(cast(ubyte[]) hexString!"559dab8c35b5852026a9a0584bbbba08f64e88eb"),
	DHTId(cast(ubyte[]) hexString!"5f319614d46d173e850ae98185be9c50b8698721"),
	DHTId(cast(ubyte[]) hexString!"67777f0513a74ac85efbff17f929e2bc030d96af"),
	DHTId(cast(ubyte[]) hexString!"6973588a3692b0139a4a1c8e6ee792b3cf947e9b"),
	DHTId(cast(ubyte[]) hexString!"6c4af38bc6004ca80d0216296a6e451387e73993"),
	DHTId(cast(ubyte[]) hexString!"71cd544f2b058e185b0264ed107389ac9c66aae6"),
	DHTId(cast(ubyte[]) hexString!"73ea6d5ece7d485ab89575562454d5ada3a287ce"),
	DHTId(cast(ubyte[]) hexString!"7431a969b347e14bba641b3517c024f7b40dfb7f"),
	DHTId(cast(ubyte[]) hexString!"7bb6ff4ead15cc0b82eb15977fe5b9b215041368"),
	DHTId(cast(ubyte[]) hexString!"858cf37bdd793a97f608c18de74ba162099256a8"),
	DHTId(cast(ubyte[]) hexString!"8a89b8a94aa587d52de819cdeadc83ac198f258b"),
	DHTId(cast(ubyte[]) hexString!"8d68807cd94d15cdd5070a37e20f69197e934ba3"),
	DHTId(cast(ubyte[]) hexString!"976eec60f66c6acc050a70428b8e0b7f8db3e4f7"),
	DHTId(cast(ubyte[]) hexString!"987255cfd8f31dd4d133dff20a6a3def0409f9b8"),
	DHTId(cast(ubyte[]) hexString!"9ffe30f02aa065bf723ebb92965f076d6fd467c7"),
	DHTId(cast(ubyte[]) hexString!"a0b5d95dc477bdaa8105477da1ff8daa8a45ebe4"),
	DHTId(cast(ubyte[]) hexString!"a258799175d7341dd8897eb06946c81a1f17f6eb"),
	DHTId(cast(ubyte[]) hexString!"a2bb38d20323e8b4eef52198f6cb31d951be657e"),
	DHTId(cast(ubyte[]) hexString!"a9c9a6a56562a254c76b43bcfbb39bbcd5e6d9b9"),
	DHTId(cast(ubyte[]) hexString!"ac79a849f6cfb95ceefdf12b9f5fc6de87c76ba5"),
	DHTId(cast(ubyte[]) hexString!"ae3d9b55731b4c04376887864e9848d6d683c3c9"),
	DHTId(cast(ubyte[]) hexString!"b1f8e90dc1e922f9e489895ef80f4e01cc1a1eec"),
	DHTId(cast(ubyte[]) hexString!"b21866d787c37eb00b4679d8cc4cbbfdb31f5ba8"),
	DHTId(cast(ubyte[]) hexString!"b4443a7b287e329a6dc5bb2a0679db4739d99d64"),
	DHTId(cast(ubyte[]) hexString!"bd44c786aa5d9f3acf06720b6d9208fb4920fe9b"),
	DHTId(cast(ubyte[]) hexString!"bfe9060dc7f453f742b58c1f103b0d61f5d0e4de"),
	DHTId(cast(ubyte[]) hexString!"c372c540570738ddd0bbb685233ae7ee47ef5854"),
	DHTId(cast(ubyte[]) hexString!"c6a9f4c6421f8ba57c1a1645ad95c15c647d7901"),
	DHTId(cast(ubyte[]) hexString!"c777c633b29c882387e789b8686b179ff90b22d1"),
	DHTId(cast(ubyte[]) hexString!"c9654595270296c3c2406386d4cdf4795f04b3f0"),
	DHTId(cast(ubyte[]) hexString!"cb17e8e28e4a6dbd95425259bbf0364cc3f04b97"),
	DHTId(cast(ubyte[]) hexString!"cc894d2d9f0434094970ce13275355f88006053e"),
	DHTId(cast(ubyte[]) hexString!"d4abefdf19c5a9ab73ced389faca97bdcbb2ef3f"),
	DHTId(cast(ubyte[]) hexString!"d9614c8632585856cb3472d679fd4990083a2461"),
	DHTId(cast(ubyte[]) hexString!"dca502e2fe385cc7c9e6c53618d5e55c5820a4b6"),
	DHTId(cast(ubyte[]) hexString!"dcb7efe95fb15aa5b543dcbd6d13e7e2dcde8320"),
	DHTId(cast(ubyte[]) hexString!"e2b150e872f3f98903ad65b77e8ea56095805a1f"),
	DHTId(cast(ubyte[]) hexString!"e68d6cfa8f95727ff75b04512f759c45f868337b"),
	DHTId(cast(ubyte[]) hexString!"e8a76cf9d8f3bcf4293a5a53e5c1314139d7ee1c"),
	DHTId(cast(ubyte[]) hexString!"edf2e0024765392c518df916c6882884e5f1c21a"),
	DHTId(cast(ubyte[]) hexString!"ee3973e4b8baa604d5a5d0d54007c88fe8e678c6"),
	DHTId(cast(ubyte[]) hexString!"f205f6e9084f0fdfdb6ed295c8035ab7b318049d"),
	DHTId(cast(ubyte[]) hexString!"f84736dbdf4eac539b89c931377570214addb838"),
	DHTId(cast(ubyte[]) hexString!"fd5fdf21aef4505451861da97aa39000ed852988"),
];


