/**
 * dht_example: Example mini application using dht-d
 *
 * Copyright (c) 2016-2018 Stefan Schuerger
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
import core.thread;

import dht;

static string nodes_filename = "nodes.sav";
static string nodes6_filename = "nodes6.sav";
static string search_filename = "search.txt";

static bool ipv4wanted = false;
static ipv6wanted = false;

static const ushort announce_port_default = 0;
static ushort announce_port = announce_port_default;


int main(string[] args){
    bool quiet = false;
    bool verbose    = false;
    bool do_search  = false;
    bool do_boot_search = false;
    ushort search_interval_default = 15;
    ushort search_interval = search_interval_default;
    ushort print_buckets_default = 60;
    ushort print_buckets = print_buckets_default;
    ushort myport;
    
	// Signal handling: save nodes before exiting (HUP, INT, TERM); 
	// USR1 triggers bucket status dump and nodes save
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
    "announce-port|p", "Perform all (non-boot) searches as announcements, using this port. Default is 0 (no announce).", &announce_port,
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
    my_id.id32[0] ^= getpid();
    
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
    
    DHT dht = new DHT(my_id,my_id,s,s6,(tp,id,ad){ 
	writeln("Callback for ", id, ": ",tp,"[",ad.length ,"]");
	writeln(ad.map!(to!string).array.join(", "));
    });
    fLog.info("My ID: " ~ my_id.toString);

    if(load(dht)) {}
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
	        dht.new_search(sample_info_hashes[uniform(0,sample_info_hashes.length)],announce_port);
	        next_search = dht.now + search_interval;
	    }
	    flag_search = false;
	}
        
        // Show buckets
	if(flag_buckets || (print_buckets > 0 && lastshow <= dht.now - print_buckets)){
            fLog.critical(dht);
	    lastshow = dht.now;
	    flag_buckets = false;
            save(dht);
	}
	
	if(flag_exit){
	    fLog.warning("SIGINT caught, exiting.");
	    break;	
	}
	
        if(exists(search_filename) && isFile(search_filename))
            load_searches(dht,search_filename);
	
	
    } 

    save(dht);
    
    return 0;
}

static bool load(DHT dht){
    bool loaded_something = false;
    if(ipv4wanted && exists(nodes_filename)  && isFile(nodes_filename)){
        load(dht,nodes_filename,false);
	loaded_something = true;
    }
    if(ipv6wanted && exists(nodes6_filename)  && isFile(nodes6_filename)){
        load(dht,nodes6_filename,true);
	loaded_something = true;
    }
    dht.id_check();
    return loaded_something;
}	

static void load(DHT dht,string fname,bool isv6){
    auto f = File(fname,"rb");

    DHT.DHTInfo* pinfo = (isv6 ? &dht.info6 : &dht.info);
    
    pinfo.myid = DHTId(f.readln().chomp);               // Line 1: ID
    pinfo.own_ip = parseAddress(f.readln().chomp).to_subtype().to_blob(); // Lin2 2: Address
    
    // remove port part
    if(pinfo.own_ip.length == 6)
        pinfo.own_ip = pinfo.own_ip[0..4]; 
    else if(pinfo.own_ip.length == 18)
        pinfo.own_ip = pinfo.own_ip[0..16];
    
    
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
	Address address = parseAddress(addressline,to!ushort(portline)).to_subtype();
        dht.insert_node(id,address,true);
    }
}

static void save(DHT dht){
    if(ipv4wanted)
        save(dht,nodes_filename,false);
    if(ipv6wanted)
        save(dht,nodes6_filename,true);
}    


static void save(DHT dht, string fname,bool isv6){
    auto f = File(fname ~ ".tmp","wb");
    
    DHT.DHTInfo* pinfo = (isv6 ? &dht.info6 : &dht.info);
    Address address = to_address(pinfo.own_ip);
    
    f.writeln(pinfo.myid);
    f.writeln(address.toAddrString());
    
    foreach(node; dht.get_nodes(isv6 ? DHTProtocol.want6 : DHTProtocol.want4)){
        f.writeln(node.id);
        f.writeln(node.address.toAddrString());
        f.writeln(node.address.toPortString());
    }
    f.flush();
    f.close();
    try
        rename(fname ~ ".tmp",fname);    
    catch(Exception e) 
        fLog.warning("rename failed: \n", e);
}

static void load_searches(DHT dht,string fname){
    File f;
    try{
        rename(fname,fname ~ ".inprogress");
        f = File(fname ~ ".inprogress","rb");
    }
    catch(Exception e){ 
        fLog.warning("open failed: \n", e);
	return;
    }
    
    string idline;
    while((idline = f.readln()) !is null){
	idline = idline.chomp;
	DHTId id = DHTId(idline);
	dht.new_search(id,announce_port);
    }
    f.close();
    rename(fname ~ ".inprogress",fname ~ ".done");
}




// Sample IDs to search for:
// Info hashes of Debian distro files
// fetched with 
//   wget http://bttracker.debian.org:6969/stat -O- \
//   | perl -ne 'print qq{\tDHTId(cast(ubyte[]) hexString!"$1"),\n} if /([0-9a-f]{40})/' | sort -u
// Here: filtered by grep amd64 | grep netinst
DHTId[] sample_info_hashes = [
	DHTId(cast(ubyte[]) hexString!"001b63a1d0bda185c3460b17d20fc3a4b9ec96d2"),
	DHTId(cast(ubyte[]) hexString!"0087c0ab74ffe14f416460e283381f1a9e94bd67"),
	DHTId(cast(ubyte[]) hexString!"0098e86ab3d9b30583601e89f8f5c13cd7d83d38"),
	DHTId(cast(ubyte[]) hexString!"02473d72efbe3ab328ace83ac05e5ce35d52aea5"),
	DHTId(cast(ubyte[]) hexString!"02ada7235907bbc946a72b50765682c908b9ee83"),
	DHTId(cast(ubyte[]) hexString!"02fb95a0f2667b3b253b30f7ce96f2eb4ab4121e"),
	DHTId(cast(ubyte[]) hexString!"04db7f1c79f8447c9c3c9a7f67493b17c177408b"),
	DHTId(cast(ubyte[]) hexString!"05b4de6bba444fb944a1dea9422ebddcc6bcb713"),
	DHTId(cast(ubyte[]) hexString!"06b1f0752bf579fdeae0f14c022e4765029f37de"),
	DHTId(cast(ubyte[]) hexString!"07af529b0c23522a837603f79f6a9bbe4f2ab303"),
	DHTId(cast(ubyte[]) hexString!"07e3ed5954ab4652439ca0068df830e616ef9083"),
	DHTId(cast(ubyte[]) hexString!"08988c9e747bbf3495693375bd7ffaf5a14ba7fa"),
	DHTId(cast(ubyte[]) hexString!"095776de8402dfdad15e17c11a1805ba70f6016d"),
	DHTId(cast(ubyte[]) hexString!"097a1f22cc51458eef4f95d7c8b425b6a83c4d88"),
	DHTId(cast(ubyte[]) hexString!"09d4b9cfba004857c0e13ccc45868bc7df7e0396"),
	DHTId(cast(ubyte[]) hexString!"0a4d0c1aa66bb58087fc65a836f5b5c6884cfb3a"),
	DHTId(cast(ubyte[]) hexString!"0ae5a604e50461f8b3957a4e52ee1cde7e0fe3c5"),
	DHTId(cast(ubyte[]) hexString!"0b7b4efe5f5db02c3a27fe1dbca4f2dc44876e0c"),
	DHTId(cast(ubyte[]) hexString!"0bfb1d88e66cb04ebbfe098d0fb20f20aec6bc5d"),
	DHTId(cast(ubyte[]) hexString!"0c26bebd631cee25f48bb856d4e0c2ff53bd1a2e"),
	DHTId(cast(ubyte[]) hexString!"0c2afc85832e513b374e262eaa4e989e43bccbac"),
	DHTId(cast(ubyte[]) hexString!"0c47a9829e33a7e4fc509a11345b6b2ec5e50518"),
	DHTId(cast(ubyte[]) hexString!"0c51336f0acb497029f1d41892d77ba34f246aea"),
	DHTId(cast(ubyte[]) hexString!"0c9b5400ec96197d751dff68595b2b78c69e5c94"),
	DHTId(cast(ubyte[]) hexString!"0d726181e70d2326be1688f20f617d90cedddb8b"),
	DHTId(cast(ubyte[]) hexString!"0ea11e59be7b78a01668aa4b4839d7eeafc36c15"),
	DHTId(cast(ubyte[]) hexString!"0ee65faf5530175b989ad0994ee997d8a1940020"),
	DHTId(cast(ubyte[]) hexString!"108e04afe81a392a8a398a40f652f93eee74f046"),
	DHTId(cast(ubyte[]) hexString!"10bd7cf0c94693b8c0711c996fd2564bedb4daf0"),
	DHTId(cast(ubyte[]) hexString!"10bf48a8ae10fefc568af2b6a726e03c46146f9a"),
	DHTId(cast(ubyte[]) hexString!"115fbddf6805804717475493fc5fdff39071cfe4"),
	DHTId(cast(ubyte[]) hexString!"1178b939c78fd7863714f3f04207c43eb840082d"),
	DHTId(cast(ubyte[]) hexString!"13a7c1f3b79b51c1dadb5b179a0bc0fb2bf167bd"),
	DHTId(cast(ubyte[]) hexString!"13b03f07dfeb204b484e3c17738cc9acd8477c10"),
	DHTId(cast(ubyte[]) hexString!"13f02f65f484b978002fed1b0f4323a8d6c084de"),
	DHTId(cast(ubyte[]) hexString!"147d1c4688d1c22bc12ac6e98435107585d24dfd"),
	DHTId(cast(ubyte[]) hexString!"1558ea053624b7b04e6608b8794fd568a93702c5"),
	DHTId(cast(ubyte[]) hexString!"15a8bfd12c7ed1afb31ac4589080d89d83a60645"),
	DHTId(cast(ubyte[]) hexString!"1605670d2bcb1bc604e4537be86094f15a8b2f90"),
	DHTId(cast(ubyte[]) hexString!"1670b2465b5f78f9fe385be2afd596e34cf1e477"),
	DHTId(cast(ubyte[]) hexString!"16c816c42f0c6730675b9969bb43144d4d660e3d"),
	DHTId(cast(ubyte[]) hexString!"16ff66e78941de098cf29089904ac5ae78dfc66f"),
	DHTId(cast(ubyte[]) hexString!"17c311e432751191fb08736dfd5ddff116fd0500"),
	DHTId(cast(ubyte[]) hexString!"180cc9539d032d7408d301298443e04dac0a5c60"),
	DHTId(cast(ubyte[]) hexString!"193d1e8e54e3d595ba087f02c914f90b1c80024d"),
	DHTId(cast(ubyte[]) hexString!"194a1ddf887d189c33d45b0f8004675d65d4ba9e"),
	DHTId(cast(ubyte[]) hexString!"1950fa9f98f44b214b1043982a822f18156a0a96"),
	DHTId(cast(ubyte[]) hexString!"19c234165421a2394859295327e5331186f3bd63"),
	DHTId(cast(ubyte[]) hexString!"1b2e3bd2f4ca40d80759b4ec5a7a8720a1491cb7"),
	DHTId(cast(ubyte[]) hexString!"1b7d455df76b5c95634ffa6759317c79a6699a44"),
	DHTId(cast(ubyte[]) hexString!"1c09fe45b21e41f96aa4cad042ea34537b16aff0"),
	DHTId(cast(ubyte[]) hexString!"1c60cbecf4c632edc7ab546623454b33a295ccea"),
	DHTId(cast(ubyte[]) hexString!"1c73e022e99870889159af40c7d3585d5bd6825d"),
	DHTId(cast(ubyte[]) hexString!"1d56ff85370e69d229f7a5795f4e713921caf0fd"),
	DHTId(cast(ubyte[]) hexString!"1d7b2efeb4cb91201557a0d494ba36d2bf688810"),
	DHTId(cast(ubyte[]) hexString!"1dadbb8451dddf23adb276d0c887ef60ec49989e"),
	DHTId(cast(ubyte[]) hexString!"1e0d47d316d0defc6d0905d3375e11ee4a854379"),
	DHTId(cast(ubyte[]) hexString!"1e0dd40f07a582e950a110eeb6fecd2554a75dcb"),
	DHTId(cast(ubyte[]) hexString!"1e4e4694b7b11bc503ed3b6038aa033b86af5e18"),
	DHTId(cast(ubyte[]) hexString!"1e6ef3312582644a6a17422c0d9ea5f8c38111d2"),
	DHTId(cast(ubyte[]) hexString!"1f6338e01320ff6896ed0563146445308b31c06a"),
	DHTId(cast(ubyte[]) hexString!"1f865306ccc3ad8ac9235965f274e5afb84b5cf1"),
	DHTId(cast(ubyte[]) hexString!"1ff33e08bc413e3da947cf10a2f42e047561692b"),
	DHTId(cast(ubyte[]) hexString!"1ffbe93e3e88103fad9681c779b54902536460ba"),
	DHTId(cast(ubyte[]) hexString!"203e072a19daee875867160053cb6fff37d8aa7c"),
	DHTId(cast(ubyte[]) hexString!"216ce37882378fa901d5d51c9a6a8bd031df1c29"),
	DHTId(cast(ubyte[]) hexString!"218d435605b99e3a2e5f2425950a36b230191009"),
	DHTId(cast(ubyte[]) hexString!"2190907a3a0e31ec02840c8034bb53588f4334b3"),
	DHTId(cast(ubyte[]) hexString!"219ff979960628404b1822869d3d2069e6ca9bc7"),
	DHTId(cast(ubyte[]) hexString!"22c541883eedc640e7cabd22e4b814a1cba6d8ad"),
	DHTId(cast(ubyte[]) hexString!"244747786b26ab3bb75e36e79df86f514a90fb3f"),
	DHTId(cast(ubyte[]) hexString!"255587c7c68295c454085e32d5f1b65c0975a0f5"),
	DHTId(cast(ubyte[]) hexString!"256228fcf4ad88a87f9fbb1efd43978c9d4bd1b8"),
	DHTId(cast(ubyte[]) hexString!"26d017bc5a4bee5c2c69fa5aec08b7da0dcff368"),
	DHTId(cast(ubyte[]) hexString!"279721e987d173d825ae5ab00646a1e1832ebac5"),
	DHTId(cast(ubyte[]) hexString!"27a71ccb816454c48056c88254d2c46909c73cf9"),
	DHTId(cast(ubyte[]) hexString!"284a4f741c973162cdc34ff64fcd291382082553"),
	DHTId(cast(ubyte[]) hexString!"29397fe716cc6698bdaf6b813993b88e1ad7a86b"),
	DHTId(cast(ubyte[]) hexString!"297acd1a5d6ba3e1ab881e27acb73843a6e81430"),
	DHTId(cast(ubyte[]) hexString!"29d9900f63d8f7407df24a9428898c3bd5e1dafa"),
	DHTId(cast(ubyte[]) hexString!"2a02d618c56faf948cbd2abb09bbdf90845ce498"),
	DHTId(cast(ubyte[]) hexString!"2b41a32c76533a5571a46e65c8c1d58dfdf10863"),
	DHTId(cast(ubyte[]) hexString!"2b4c6a0bd5d77c7a1cb6c61ec40d0aba4958d1a5"),
	DHTId(cast(ubyte[]) hexString!"2c5bfeebe85fe35b6b85f1663a1e921206e3ef44"),
	DHTId(cast(ubyte[]) hexString!"2c79686e9bb96835ee024fbfa04d74ac668aeae7"),
	DHTId(cast(ubyte[]) hexString!"2df625bcfce1583b84e59bf3c81f750851ca6d34"),
	DHTId(cast(ubyte[]) hexString!"2e370910ebe3d4eebde1ef6af0a45a18f840f2c2"),
	DHTId(cast(ubyte[]) hexString!"2e8e9972ab0f1f8ec1fe65f3b177a8d58af07271"),
	DHTId(cast(ubyte[]) hexString!"2ea1d96f7c74bf446cf77273a5e112f9da4ce1bf"),
	DHTId(cast(ubyte[]) hexString!"301f9304a4d1cb82d5630777e5913c026250bc06"),
	DHTId(cast(ubyte[]) hexString!"304347bc4c692733e80b281ef888b5b567f9e45c"),
	DHTId(cast(ubyte[]) hexString!"308f77b9aedac136ec0c1eedc32a1d352a86e56b"),
	DHTId(cast(ubyte[]) hexString!"30987c19cf0eae3cf47766f387c621fa78a58ab9"),
	DHTId(cast(ubyte[]) hexString!"30b860c99ddd7cfe43c47a90450013192d4d8301"),
	DHTId(cast(ubyte[]) hexString!"3110381baf9d0cf217d308b50e053715c38ba908"),
	DHTId(cast(ubyte[]) hexString!"315b93bf0a28e2c3cfaf83efa7f7319f05c29651"),
	DHTId(cast(ubyte[]) hexString!"3179a662b9c9ba6ec2b2c8b4f27452d061a14af9"),
	DHTId(cast(ubyte[]) hexString!"31fcfc3d9b3a6ae4eb0b40a7ef6903c1c3510eec"),
	DHTId(cast(ubyte[]) hexString!"32f0c5770e361bf0d48652afddc87ded8e772661"),
	DHTId(cast(ubyte[]) hexString!"3306395a4f132eca38b436b84dd72c4d9d87def2"),
	DHTId(cast(ubyte[]) hexString!"341d5062621b105bb43a43fec55c17d028fbf433"),
	DHTId(cast(ubyte[]) hexString!"34da040808e2ffca817a36827f03c2186e98f1dc"),
	DHTId(cast(ubyte[]) hexString!"36c89d9b73f42ec1ccbd0590a615762e5e60856c"),
	DHTId(cast(ubyte[]) hexString!"3727e176a8187e7e6855be546f442b8a999d516b"),
	DHTId(cast(ubyte[]) hexString!"37919ce8185946f06bbe7fc8267460aa925cf519"),
	DHTId(cast(ubyte[]) hexString!"37b6a5fa3af60b797d9ce49260dea24f5d2ecbc8"),
	DHTId(cast(ubyte[]) hexString!"3831f82f0c5c3a228d19f16ad8cdf3d5eed78aeb"),
	DHTId(cast(ubyte[]) hexString!"383abcfaa546039d1ee56d27914bcc2276d604aa"),
	DHTId(cast(ubyte[]) hexString!"383ca1eb28affe9be1756e808f717fe35ef3599f"),
	DHTId(cast(ubyte[]) hexString!"3901795f13594e3812313e4209c04cff902f407c"),
	DHTId(cast(ubyte[]) hexString!"3a32cde4576f81fbd292644b70924606b6a99525"),
	DHTId(cast(ubyte[]) hexString!"3a9c2c3ae6e64373516aa615296b525044a1fca6"),
	DHTId(cast(ubyte[]) hexString!"3b2b847377f760512cb0483d2dfce82f36aea74b"),
	DHTId(cast(ubyte[]) hexString!"3b39ad882a5ce47fd49d93bd75a6477a93331e07"),
	DHTId(cast(ubyte[]) hexString!"3bd7f2013a1baeb3e985136b522a2cc9e90303a7"),
	DHTId(cast(ubyte[]) hexString!"3c12d298b4de623ead343c8af160172f5f95683b"),
	DHTId(cast(ubyte[]) hexString!"3c4ee82482a038805208479595deb44662bc84c1"),
	DHTId(cast(ubyte[]) hexString!"3c7848ab3769a6be8b23e2ec2d157d182b16063e"),
	DHTId(cast(ubyte[]) hexString!"3cfb550ecdd9134c3b2606bea2dfca3df7561c3c"),
	DHTId(cast(ubyte[]) hexString!"3cfbb22bc9f8eae2a81def8870542c534b169ca3"),
	DHTId(cast(ubyte[]) hexString!"3d4efce4e30a4938ed31b2dcac6b3c8d2808fb3e"),
	DHTId(cast(ubyte[]) hexString!"3d8ccc2b99e41325f06a97a156eaeb53a81a88f4"),
	DHTId(cast(ubyte[]) hexString!"3d8d59b17be25dae5271aaf21570da31519ca841"),
	DHTId(cast(ubyte[]) hexString!"3e21e33a071c9d093535a30dca71c9e5ae67809b"),
	DHTId(cast(ubyte[]) hexString!"3f35331a9274456d940e161adb52dd051537687f"),
	DHTId(cast(ubyte[]) hexString!"3f601d7604e1fef13a8d2cea3c77513e9755fcd5"),
	DHTId(cast(ubyte[]) hexString!"3f87043453de9a8fccccb8db67f3d20b5ff20e92"),
	DHTId(cast(ubyte[]) hexString!"3ffe8f65c3f7349e6b0dfa58d2bf1b3e667e58c0"),
	DHTId(cast(ubyte[]) hexString!"40218a2b720c332d71432a0d01e320913fb04b7b"),
	DHTId(cast(ubyte[]) hexString!"404aa25dc53a6f9552330cb223c9179e55a49adf"),
	DHTId(cast(ubyte[]) hexString!"405640f22c66939fba32256865598278f6044ffe"),
	DHTId(cast(ubyte[]) hexString!"407e126d838d10939a5682aa3df5c5731affbe0e"),
	DHTId(cast(ubyte[]) hexString!"40d774417d6342a5d088504a7e98dc842c133b22"),
	DHTId(cast(ubyte[]) hexString!"40f90995a1c16a1bf454d09907f57700f3e8bd64"),
	DHTId(cast(ubyte[]) hexString!"4126f584568002cd3c2074a7ac6bda0a1058f622"),
	DHTId(cast(ubyte[]) hexString!"417ec4126faba917a98b7e295c90468cb563c126"),
	DHTId(cast(ubyte[]) hexString!"4194e473d6c49630e1c6247d6716076809bb96ae"),
	DHTId(cast(ubyte[]) hexString!"42e1deddb973a299d91644ca7c6150df882cc0cf"),
	DHTId(cast(ubyte[]) hexString!"4323cd278fb21f8975dacb311fca2eb016056d07"),
	DHTId(cast(ubyte[]) hexString!"4371e53fa9487d63fd3a121eed99a2de6ca925ba"),
	DHTId(cast(ubyte[]) hexString!"43a7a2e128d5dfb850d04ec00fb04e4a67c640fd"),
	DHTId(cast(ubyte[]) hexString!"43cf2cecd2154ee4146c3650167cb6cb25fe4b67"),
	DHTId(cast(ubyte[]) hexString!"440636d789ac8699e505e7862c80d8171a81ceef"),
	DHTId(cast(ubyte[]) hexString!"44f1b8d27ccaca85344243bf7cecc1f45d66911d"),
	DHTId(cast(ubyte[]) hexString!"45cf9190024552f89d3b5bdc341b38feb0c8b89d"),
	DHTId(cast(ubyte[]) hexString!"45d33ca56084d06233fcfae9f2192ef43636ee74"),
	DHTId(cast(ubyte[]) hexString!"4621c4df1ad5c46957e4b9d1c5a49fc376c0c1bd"),
	DHTId(cast(ubyte[]) hexString!"462f06b20a1160191a08f4fbc2e46449193ded35"),
	DHTId(cast(ubyte[]) hexString!"46d16f15a3122d17bda40de1f7110f7a899cef7a"),
	DHTId(cast(ubyte[]) hexString!"470c1dd945b8df95726750b68e019a993270041c"),
	DHTId(cast(ubyte[]) hexString!"478fa321d3196ca560870e56762ae8984f333672"),
	DHTId(cast(ubyte[]) hexString!"47b9ad52c009f3bd562ffc6da40e5c55d3fb47f3"),
	DHTId(cast(ubyte[]) hexString!"489cde10294e16bf377719e088d161cd4bf6a037"),
	DHTId(cast(ubyte[]) hexString!"4a079ef2026aa795ba6487f9a76f811552808be8"),
	DHTId(cast(ubyte[]) hexString!"4b1e17a169ce38f276e7f4ca86d0ad0089b04ae8"),
	DHTId(cast(ubyte[]) hexString!"4b54363140afafab7f4cc6872c9357075014078d"),
	DHTId(cast(ubyte[]) hexString!"4b80577d28584e954df7c41821191bb15e5958f6"),
	DHTId(cast(ubyte[]) hexString!"4bd01763a6e92cde1b4fb7b514d4084d85248d20"),
	DHTId(cast(ubyte[]) hexString!"4c0984b6dd014cedb10beba23de9c5f0a409b327"),
	DHTId(cast(ubyte[]) hexString!"4cf2fa5b27cbad86ac42777bb3e2d0cdcf45ff69"),
	DHTId(cast(ubyte[]) hexString!"4d287f37d16722053af7e54bce87f5b37170cb8d"),
	DHTId(cast(ubyte[]) hexString!"4d732b944a1aa4f25e8ffaff2cd8a609bf19cba0"),
	DHTId(cast(ubyte[]) hexString!"4dec779438b04b757705a0b3b5ecefe989c2d71d"),
	DHTId(cast(ubyte[]) hexString!"4eb52e54e838c33991d0eff506b256378fef61db"),
	DHTId(cast(ubyte[]) hexString!"4ef3219fe92a44d3a1a49ef0a6d8df1a3f45b593"),
	DHTId(cast(ubyte[]) hexString!"4f27e1cb827dd82ce7d3923049e575c95bd1e481"),
	DHTId(cast(ubyte[]) hexString!"4f4d92cd839e6d475daadeba79ff56adb884c1c6"),
	DHTId(cast(ubyte[]) hexString!"4f687d8a140e58d3d7172d5f8569887a255938e5"),
	DHTId(cast(ubyte[]) hexString!"51273f52eb85bbd1318faa053e9091faa4fa1f51"),
	DHTId(cast(ubyte[]) hexString!"5145de11aec9a8943c9f99d88013bf2f21b64b6a"),
	DHTId(cast(ubyte[]) hexString!"51f6d5c27442e5058a2c9da8bb9043842391e58e"),
	DHTId(cast(ubyte[]) hexString!"538367aa84731126d3d929a93dbb2f47c0e46658"),
	DHTId(cast(ubyte[]) hexString!"53d360404a18c98a4fefa2b3fc8fa00577d78c51"),
	DHTId(cast(ubyte[]) hexString!"53dcd5c0d46c331d6fe354625b38aa6a89a558fc"),
	DHTId(cast(ubyte[]) hexString!"53de12bd112792bbfdff406d9cd28909b53b954d"),
	DHTId(cast(ubyte[]) hexString!"54328f0af627a02b3207c8f916e55d13f9fc25e2"),
	DHTId(cast(ubyte[]) hexString!"5471f01f3814173869ef88f24056191ccd935396"),
	DHTId(cast(ubyte[]) hexString!"54f94fe4001323e6e8c9fba9dc7279a2b07493ed"),
	DHTId(cast(ubyte[]) hexString!"5530ca765160f72430ffc0dda8344836b9070932"),
	DHTId(cast(ubyte[]) hexString!"559dab8c35b5852026a9a0584bbbba08f64e88eb"),
	DHTId(cast(ubyte[]) hexString!"55d96810e7332666d8133f228b5b199562e33129"),
	DHTId(cast(ubyte[]) hexString!"55e00763c5a22f3983083ea4de7cb72db4d6ae4b"),
	DHTId(cast(ubyte[]) hexString!"5665aad63d00422bf5215567d2c63e6873f07ae8"),
	DHTId(cast(ubyte[]) hexString!"566e8d342b81f8ab8170a78f53988019c187eba7"),
	DHTId(cast(ubyte[]) hexString!"56840368c10b2369b32269bc0e8d310393088af7"),
	DHTId(cast(ubyte[]) hexString!"56a21a042238079f5cc68a81af8f3689dd923b0b"),
	DHTId(cast(ubyte[]) hexString!"56b6d1d5af1744ef70e5d31caecb83fb21e794c0"),
	DHTId(cast(ubyte[]) hexString!"57078ab1aed083151f159d99b5bd950053e12591"),
	DHTId(cast(ubyte[]) hexString!"57f1ffa6929ad3cfdd3783bf90fed9fc93d6a845"),
	DHTId(cast(ubyte[]) hexString!"5809063de8b437a342e7afec7f146735f52ec6d3"),
	DHTId(cast(ubyte[]) hexString!"5859028b50543f96c198a7e606345e1ab70363c0"),
	DHTId(cast(ubyte[]) hexString!"58e466e86c65e4e068c18668cdb3e7e9b816f941"),
	DHTId(cast(ubyte[]) hexString!"5928d420d66e4d7e7c49040d41b80d6e0922275c"),
	DHTId(cast(ubyte[]) hexString!"5930d2e07198620e1356b3f0ad20c56e9de498e7"),
	DHTId(cast(ubyte[]) hexString!"59c0545a0bbe7629a179b339dc84779d259b6a9b"),
	DHTId(cast(ubyte[]) hexString!"5a55916299e671e537af403b33627f455b4de8d8"),
	DHTId(cast(ubyte[]) hexString!"5b80e80dc95b2e57887a607cee1dded95c057d89"),
	DHTId(cast(ubyte[]) hexString!"5bd1458ca03f5190084af931617b86a0810f4e55"),
	DHTId(cast(ubyte[]) hexString!"5c0e65ca613f23ae1191a9f49ca68507e97a94ab"),
	DHTId(cast(ubyte[]) hexString!"5d1fdde32a0004e7a024f829bf071c6ee4bf258c"),
	DHTId(cast(ubyte[]) hexString!"5d25472f42376ed7e9f3387d01c1c1d5fd864c87"),
	DHTId(cast(ubyte[]) hexString!"5d893f5e89b2cf7f4fc9df7d2f48d0dc9d54ec13"),
	DHTId(cast(ubyte[]) hexString!"5db91573aa0dd8d3cf9d0ce299a2a1bd714af30e"),
	DHTId(cast(ubyte[]) hexString!"5e1e54a4cdc2cd415199f8e2a00623d21c5d4e7c"),
	DHTId(cast(ubyte[]) hexString!"5f319614d46d173e850ae98185be9c50b8698721"),
	DHTId(cast(ubyte[]) hexString!"5f799439233425dd2e78081ac41ab71fde241819"),
	DHTId(cast(ubyte[]) hexString!"5f829153f6c644cb0fc3acf5cfff6c69359c1c72"),
	DHTId(cast(ubyte[]) hexString!"5fc156e11831fc4f8340c09f0d25711fabfae54e"),
	DHTId(cast(ubyte[]) hexString!"6060119866afa0046405d0e7a6a332094d1912e2"),
	DHTId(cast(ubyte[]) hexString!"60e092e127d2de347ae092edc04ddd91d6ccf70d"),
	DHTId(cast(ubyte[]) hexString!"611e2cd9060d670cf9619086c3fad2250eee83bb"),
	DHTId(cast(ubyte[]) hexString!"61cd5b1b1d239863cca3923a578c403338a622b7"),
	DHTId(cast(ubyte[]) hexString!"620c571308ee3d4b3f3f0811aaef0c45361b29a5"),
	DHTId(cast(ubyte[]) hexString!"624861f13d1034194354eaaaf35ce9d5027491c9"),
	DHTId(cast(ubyte[]) hexString!"624e8deef7ffd5fb207e38995de5fe1aec11076d"),
	DHTId(cast(ubyte[]) hexString!"627fdf1d744f4e605a783fc63da54cb2d8a3db14"),
	DHTId(cast(ubyte[]) hexString!"6284fb28406b805b1125e48042e0ed47a3ebab86"),
	DHTId(cast(ubyte[]) hexString!"63515d99e2a99e79526e35c9a39a1dfd843027a0"),
	DHTId(cast(ubyte[]) hexString!"635c18280081ae6e03a8011e8ba130538889b4b8"),
	DHTId(cast(ubyte[]) hexString!"637cd170c9b67b9bc81089224b7429183d53ec14"),
	DHTId(cast(ubyte[]) hexString!"63b15719694adda9ed4b0bae900b0003977c2dee"),
	DHTId(cast(ubyte[]) hexString!"640203fae6d9a4cfe4eebca4ff4ed523b23d5472"),
	DHTId(cast(ubyte[]) hexString!"640cdf9497dbd8abe3fe1f7b0b371ffb605912ce"),
	DHTId(cast(ubyte[]) hexString!"6472959c54c38b3ffa0dddbeb8797d975f04faf3"),
	DHTId(cast(ubyte[]) hexString!"6477fec40373c3ac81820eff27460d68b242990a"),
	DHTId(cast(ubyte[]) hexString!"65d7bbfe8abaeaa6260741e8ec4506396e17a99a"),
	DHTId(cast(ubyte[]) hexString!"65f31451bc5454a34f57b84f628ce2c2949f6241"),
	DHTId(cast(ubyte[]) hexString!"66677f49fd4ee8ef7ed76f31625096c30c488900"),
	DHTId(cast(ubyte[]) hexString!"673d915718445a8d4a77416f3d6d978a73924e99"),
	DHTId(cast(ubyte[]) hexString!"67777f0513a74ac85efbff17f929e2bc030d96af"),
	DHTId(cast(ubyte[]) hexString!"682f1f6e26104acfa1d3682ed95de0a7b86062e8"),
	DHTId(cast(ubyte[]) hexString!"683a5ccf971d64de598efb428cfadefd2d1f81c6"),
	DHTId(cast(ubyte[]) hexString!"6973588a3692b0139a4a1c8e6ee792b3cf947e9b"),
	DHTId(cast(ubyte[]) hexString!"69a40beddfdebac777fc62891ad3b87e006a3320"),
	DHTId(cast(ubyte[]) hexString!"69ce1f603bc633da77a11ecc28ff4ae4dc52a9b1"),
	DHTId(cast(ubyte[]) hexString!"6a06d5b4304b285074e4470986a613e5393de102"),
	DHTId(cast(ubyte[]) hexString!"6b003df86de2716bfa1e28a7987ad22220bf98d4"),
	DHTId(cast(ubyte[]) hexString!"6b29b1d25f9d4b1758f8ae2155cec4d8844be001"),
	DHTId(cast(ubyte[]) hexString!"6c4af38bc6004ca80d0216296a6e451387e73993"),
	DHTId(cast(ubyte[]) hexString!"6c4b7b05cb5102fe463add025aeaa48b113d9dee"),
	DHTId(cast(ubyte[]) hexString!"6c93d8f5091c24db69c7d28e7d7412322e836b4c"),
	DHTId(cast(ubyte[]) hexString!"6cf1bd9c7fe24a52151ebbb5ac5c9428c874e8bc"),
	DHTId(cast(ubyte[]) hexString!"6d0883d606a1ee594e6056d99ee6c0ce90339065"),
	DHTId(cast(ubyte[]) hexString!"6d1656125bef3d1b5fd801af82f1bbcbaa034629"),
	DHTId(cast(ubyte[]) hexString!"6e6f10d1335ae543366ddf863cd9cd38499e3787"),
	DHTId(cast(ubyte[]) hexString!"6ea9b30bd960c81bd1189e74015de8ed99350e36"),
	DHTId(cast(ubyte[]) hexString!"6ee6e206a5182846633a546c5db4ab6e05665c13"),
	DHTId(cast(ubyte[]) hexString!"6f1b1e9e124efb3cd8c26ddec0d80c2c38280a6e"),
	DHTId(cast(ubyte[]) hexString!"6f41effe30b74e1a276c5e6160324df8062f41f0"),
	DHTId(cast(ubyte[]) hexString!"6f89412ad62d73234d7c5c742f530526e9c92201"),
	DHTId(cast(ubyte[]) hexString!"706cf89d06bea3d8ea4de725ba934c30e3fcb227"),
	DHTId(cast(ubyte[]) hexString!"707421b10e44707a3361f5116e2d999cae18a6e7"),
	DHTId(cast(ubyte[]) hexString!"70ad54fbe655faab75d645ef81a2dc1eca467820"),
	DHTId(cast(ubyte[]) hexString!"70cbfc3387b5b513cabad50e37303437df7e8780"),
	DHTId(cast(ubyte[]) hexString!"7155caf12b38d6960ab88a66d4bda54ce27a4381"),
	DHTId(cast(ubyte[]) hexString!"71cd544f2b058e185b0264ed107389ac9c66aae6"),
	DHTId(cast(ubyte[]) hexString!"72f45a53db4d3f6d0de33fc65250a1403f86df04"),
	DHTId(cast(ubyte[]) hexString!"7330c8b1f6f73ab6682aeec00b1d62e94e580f18"),
	DHTId(cast(ubyte[]) hexString!"73b38c5f82a28d47efef94c04d0a839b180f9ca0"),
	DHTId(cast(ubyte[]) hexString!"73ea6d5ece7d485ab89575562454d5ada3a287ce"),
	DHTId(cast(ubyte[]) hexString!"7431a969b347e14bba641b3517c024f7b40dfb7f"),
	DHTId(cast(ubyte[]) hexString!"747614fce08da70e302fe4721b05f91d2a11b41e"),
	DHTId(cast(ubyte[]) hexString!"753f47faeac9607c2827542d23c80826a37dcc93"),
	DHTId(cast(ubyte[]) hexString!"76388d8c94aebacc8fa7249d35cc62b107f65026"),
	DHTId(cast(ubyte[]) hexString!"76d40fade83526e3c6b96d73fab40a45e2969c0e"),
	DHTId(cast(ubyte[]) hexString!"76fc33efd8d09e642c8f8baa9c9192fcee7f7f0d"),
	DHTId(cast(ubyte[]) hexString!"7721e8812c3aed52be090c35265e3e3d84c2e384"),
	DHTId(cast(ubyte[]) hexString!"77879109aa83073bbb984676659e6d8d97254b12"),
	DHTId(cast(ubyte[]) hexString!"78290cfdbc07dc5b618b09d3184aead8070e13ce"),
	DHTId(cast(ubyte[]) hexString!"783e594742dfc7d8177649c506d970715051c546"),
	DHTId(cast(ubyte[]) hexString!"79034393826e576653ed0f326af58be8e8f1189e"),
	DHTId(cast(ubyte[]) hexString!"79551b93788e1c2e6fa5b9818b8982366795068b"),
	DHTId(cast(ubyte[]) hexString!"7980011d310eb8b6f8f5f593e82f83510901ce1c"),
	DHTId(cast(ubyte[]) hexString!"7a6222bfb6d45d675c91982395e9b2a9920c2050"),
	DHTId(cast(ubyte[]) hexString!"7b17121c6fbcddcbf88ccdd21da112c3aa7df164"),
	DHTId(cast(ubyte[]) hexString!"7bb6ff4ead15cc0b82eb15977fe5b9b215041368"),
	DHTId(cast(ubyte[]) hexString!"7bda52fd4b7f17d315671ad39711c4e2ece079ef"),
	DHTId(cast(ubyte[]) hexString!"7dd2bab22e776885054323860411f2772c2ef05e"),
	DHTId(cast(ubyte[]) hexString!"7e25aa3212dd1f2a24a097830a8e220a780eddad"),
	DHTId(cast(ubyte[]) hexString!"7e9afd10025167b9e83617afa10504fbbafda0e8"),
	DHTId(cast(ubyte[]) hexString!"7f4b69da8a69a0edc1bf776d29be03adac5b96c8"),
	DHTId(cast(ubyte[]) hexString!"7fe6d56406350f8aaae66cb1371a4ee7e72b1428"),
	DHTId(cast(ubyte[]) hexString!"8068511d0695b6d09188493ab45e9f035230b4bf"),
	DHTId(cast(ubyte[]) hexString!"80f4757f587deb17141d898714f2676ad2554f08"),
	DHTId(cast(ubyte[]) hexString!"8163563b7c7418a244a6edc76135e7dbe6a7c471"),
	DHTId(cast(ubyte[]) hexString!"826e955f2d7c4c1ad3fbc133346270cac641e995"),
	DHTId(cast(ubyte[]) hexString!"828e2289e73ed9c96c16203e24ebd66e198eb65f"),
	DHTId(cast(ubyte[]) hexString!"83765dd3433e8cfed1a3c7c9b95802a2f6c3ca43"),
	DHTId(cast(ubyte[]) hexString!"847292b33f08e25ed3a4c8b0d2a92f4c4ccd5672"),
	DHTId(cast(ubyte[]) hexString!"858cf37bdd793a97f608c18de74ba162099256a8"),
	DHTId(cast(ubyte[]) hexString!"85ebaa9654e53356f84ee019eb9600ba3dcf8d70"),
	DHTId(cast(ubyte[]) hexString!"86c0d780568316304a61f84bc495c5917a54be58"),
	DHTId(cast(ubyte[]) hexString!"86d84934c5eb32b62cd6ca16cae9dc186b9f6d28"),
	DHTId(cast(ubyte[]) hexString!"86f72e6b829c7e2d089b5cf0d1ded09122e65ca4"),
	DHTId(cast(ubyte[]) hexString!"87482ded0e58202522337c4b3cdbd38995adf43c"),
	DHTId(cast(ubyte[]) hexString!"879fed07662a339bf909d243d7a23f107aadde9e"),
	DHTId(cast(ubyte[]) hexString!"87fc6a6b7bfeda7841c43d913b78d9b74ec25288"),
	DHTId(cast(ubyte[]) hexString!"883c6f02fc46188ac17ea49c13c3e9d97413a5a2"),
	DHTId(cast(ubyte[]) hexString!"88a8c1054ce7623958ac601a4ba275d57e1c174a"),
	DHTId(cast(ubyte[]) hexString!"8938851a17871f06ab146bd67b2b71011b4274e4"),
	DHTId(cast(ubyte[]) hexString!"89af3de32b2359b7d22594c6d94fd6f50eb7971b"),
	DHTId(cast(ubyte[]) hexString!"89bd92a3463d93e550936707b68a7cff76984fc3"),
	DHTId(cast(ubyte[]) hexString!"8a89b8a94aa587d52de819cdeadc83ac198f258b"),
	DHTId(cast(ubyte[]) hexString!"8afaec94930b8ebf80739193e9dbc8bae947ce3f"),
	DHTId(cast(ubyte[]) hexString!"8b1de4dc23fd75707c4d0eeafe60e3ba86aabb97"),
	DHTId(cast(ubyte[]) hexString!"8b8c44e877694eeeef8ee8438d3b68402da76a36"),
	DHTId(cast(ubyte[]) hexString!"8c11a43377f350da7a88fcca195a8eb589a0971f"),
	DHTId(cast(ubyte[]) hexString!"8c2b5fc1d7b847bf639a02f16d60db98bd28292a"),
	DHTId(cast(ubyte[]) hexString!"8c2b61830ead8d74da70dca5d5a6c7b6f2aaf032"),
	DHTId(cast(ubyte[]) hexString!"8d68807cd94d15cdd5070a37e20f69197e934ba3"),
	DHTId(cast(ubyte[]) hexString!"8dd53c552956f33be82f92790995104a376deb8f"),
	DHTId(cast(ubyte[]) hexString!"902746fd7fea774f1b28aa21e2631d2b26452504"),
	DHTId(cast(ubyte[]) hexString!"9035924dfc90deee9daa2754ff8efcdb842bf906"),
	DHTId(cast(ubyte[]) hexString!"908f58a345405d494abd30cab99cbb27e79c7ace"),
	DHTId(cast(ubyte[]) hexString!"90c52b25375f12432d504bad7f587e5543f22fda"),
	DHTId(cast(ubyte[]) hexString!"90cef3ff89d70b7253b96b0ac361422f692c701a"),
	DHTId(cast(ubyte[]) hexString!"917e8043da41b35e1ca70c7ef72830f7c16caa20"),
	DHTId(cast(ubyte[]) hexString!"91981606a103242ebfcb8ef80a6db30cc07e1025"),
	DHTId(cast(ubyte[]) hexString!"91c6ab569063fef404e3e82982e0c953c1b04c01"),
	DHTId(cast(ubyte[]) hexString!"9269d77dd93001f4fb452cf208603ba7c859f971"),
	DHTId(cast(ubyte[]) hexString!"92f535c4b422fc105dd71499a611a9db39bfae38"),
	DHTId(cast(ubyte[]) hexString!"9379546f57962eccbbf72e16eeeb397d48678bf1"),
	DHTId(cast(ubyte[]) hexString!"94e9706123c053d70fe0a00409a298b1fbc8eae3"),
	DHTId(cast(ubyte[]) hexString!"9514ed6ac698f1b07568a54e2d8bcd64c1cd2ae7"),
	DHTId(cast(ubyte[]) hexString!"9575c2600b1e9a94ea58357120cc0dd391944e08"),
	DHTId(cast(ubyte[]) hexString!"976eec60f66c6acc050a70428b8e0b7f8db3e4f7"),
	DHTId(cast(ubyte[]) hexString!"97d68e40a458b3872f52695917ca3353509e4553"),
	DHTId(cast(ubyte[]) hexString!"987255cfd8f31dd4d133dff20a6a3def0409f9b8"),
	DHTId(cast(ubyte[]) hexString!"99a60c5c801f6a198063998fbec541b89568da98"),
	DHTId(cast(ubyte[]) hexString!"99aee0836476a7a1766a99010c9788d6d5bebd7b"),
	DHTId(cast(ubyte[]) hexString!"9aa0bd4cd1f251de712eeecaf6d164e11368e5b7"),
	DHTId(cast(ubyte[]) hexString!"9ab490b6107cccc864adaba1d65a07f87eeec521"),
	DHTId(cast(ubyte[]) hexString!"9ab7d619a64f389692ffa807effba3c57fa8d610"),
	DHTId(cast(ubyte[]) hexString!"9ac4283b3db65b9af4b6a68886fca07450b5d28f"),
	DHTId(cast(ubyte[]) hexString!"9b0cfc452f2d97901696e3d4c614bd038b3b5fa6"),
	DHTId(cast(ubyte[]) hexString!"9bacbb4b55771c7aafaacb2987dca17564861e07"),
	DHTId(cast(ubyte[]) hexString!"9c092319a39829b6dc488382dc1be6fb72e5b83d"),
	DHTId(cast(ubyte[]) hexString!"9c917557171c4abbf736c391f9394c4aa5b95bcb"),
	DHTId(cast(ubyte[]) hexString!"9d2ebded04d9a6f9dca56d5b37033fe7766cdace"),
	DHTId(cast(ubyte[]) hexString!"9d4047480a3422456076fa72954929c72384df20"),
	DHTId(cast(ubyte[]) hexString!"9deb5480961fb2140aaa738fd525753a12f24c04"),
	DHTId(cast(ubyte[]) hexString!"9e2c34c3fd30d25fed9a23d93fcc69ae546c1d10"),
	DHTId(cast(ubyte[]) hexString!"9ef4d3a05be289423b6b3def3eefbf953d63cff1"),
	DHTId(cast(ubyte[]) hexString!"9fb2086917271c5de8268062e58dd02c7fd0ffc6"),
	DHTId(cast(ubyte[]) hexString!"9ffe30f02aa065bf723ebb92965f076d6fd467c7"),
	DHTId(cast(ubyte[]) hexString!"a07f914f1aa2c1be37620915496df7b2c9347298"),
	DHTId(cast(ubyte[]) hexString!"a0acd4c0f35c2f96df053783a79a305326e21cc5"),
	DHTId(cast(ubyte[]) hexString!"a0b5d95dc477bdaa8105477da1ff8daa8a45ebe4"),
	DHTId(cast(ubyte[]) hexString!"a186703393eca03b03fb8aa3ed58c0ec0fb393de"),
	DHTId(cast(ubyte[]) hexString!"a258799175d7341dd8897eb06946c81a1f17f6eb"),
	DHTId(cast(ubyte[]) hexString!"a2bb38d20323e8b4eef52198f6cb31d951be657e"),
	DHTId(cast(ubyte[]) hexString!"a36b2556a2b1511f7ac24f2b25ced1bec45e2184"),
	DHTId(cast(ubyte[]) hexString!"a490cb4830107d0cf6158a6762cfa035fa3fedf7"),
	DHTId(cast(ubyte[]) hexString!"a4bf57863097a285ee7bef9537132654e22d4c50"),
	DHTId(cast(ubyte[]) hexString!"a540556ae6f524a81eda414d9904ec369aa4cb48"),
	DHTId(cast(ubyte[]) hexString!"a6b6a3a01ea777fc94898ac63333c824157d7e2b"),
	DHTId(cast(ubyte[]) hexString!"a7055d06e5a8f7f816ec01ac7f7f5243d3cb008f"),
	DHTId(cast(ubyte[]) hexString!"a724fd40729728ec9d66aa111f7dad0cbfba64d8"),
	DHTId(cast(ubyte[]) hexString!"a7890388c3701cd728f2c9f8a3e2e6134e67e187"),
	DHTId(cast(ubyte[]) hexString!"a887676b3e790dd28a92772b776199529f477762"),
	DHTId(cast(ubyte[]) hexString!"a88ffc563021d8def1154463a1202c3b4b093bbb"),
	DHTId(cast(ubyte[]) hexString!"a946fe43ffbdd32ab350c686dbfd0788f8650f47"),
	DHTId(cast(ubyte[]) hexString!"a95578f208dd2450fd9e100e23356eae5f34f76a"),
	DHTId(cast(ubyte[]) hexString!"a975fcdd510758caf995e26c7b0c17d764d814cf"),
	DHTId(cast(ubyte[]) hexString!"a9b965dac010968168e1a5e504487eaf0f114341"),
	DHTId(cast(ubyte[]) hexString!"a9c9a6a56562a254c76b43bcfbb39bbcd5e6d9b9"),
	DHTId(cast(ubyte[]) hexString!"aa143af05453be489d574976e15f4a8e3952a855"),
	DHTId(cast(ubyte[]) hexString!"aaaaf594cdd2d431ed37439fe6448d98c349cc7d"),
	DHTId(cast(ubyte[]) hexString!"ab3bdbad7086674930b1b313eda78e03e9f59f2a"),
	DHTId(cast(ubyte[]) hexString!"abbf6a07474002a22752d564513698a4ae95180f"),
	DHTId(cast(ubyte[]) hexString!"ac241759f92572e63de1ffdd1ea6baad8e5b236f"),
	DHTId(cast(ubyte[]) hexString!"ac79a849f6cfb95ceefdf12b9f5fc6de87c76ba5"),
	DHTId(cast(ubyte[]) hexString!"ae3d9b55731b4c04376887864e9848d6d683c3c9"),
	DHTId(cast(ubyte[]) hexString!"b12b44bc2a8110b84af0b15337eb86bfe85dd087"),
	DHTId(cast(ubyte[]) hexString!"b1990a0942bb6601faed326ed90c9fb373f352e2"),
	DHTId(cast(ubyte[]) hexString!"b1f050f9c92216be8157ae3f277351e8e78dfa46"),
	DHTId(cast(ubyte[]) hexString!"b1f8e90dc1e922f9e489895ef80f4e01cc1a1eec"),
	DHTId(cast(ubyte[]) hexString!"b21866d787c37eb00b4679d8cc4cbbfdb31f5ba8"),
	DHTId(cast(ubyte[]) hexString!"b2d061b01093f1074d732917f310358d0113f9bb"),
	DHTId(cast(ubyte[]) hexString!"b394a8433b452bd6b15e6b928ca50f8c63819330"),
	DHTId(cast(ubyte[]) hexString!"b3d51b850ed7cdc17e3738c8a756e170648fc48d"),
	DHTId(cast(ubyte[]) hexString!"b3efb16029abb889bebce9bed62747e61a5cc3d0"),
	DHTId(cast(ubyte[]) hexString!"b4443a7b287e329a6dc5bb2a0679db4739d99d64"),
	DHTId(cast(ubyte[]) hexString!"b49a658f99ecf621971ecc33025592c308332b1f"),
	DHTId(cast(ubyte[]) hexString!"b4f46bdb5d7f9844c56de0171632caae309d36ca"),
	DHTId(cast(ubyte[]) hexString!"b50d064e6e290ed912d618bf28943606f0d531cb"),
	DHTId(cast(ubyte[]) hexString!"b514c49170b0f8d7e9aa66f6f95c24e4c814577d"),
	DHTId(cast(ubyte[]) hexString!"b52a1e5ba7deb2ec6b234a6636c50f8c082ad87a"),
	DHTId(cast(ubyte[]) hexString!"b6497c3dbcd04735584b82a2ab885bfd541b2e17"),
	DHTId(cast(ubyte[]) hexString!"b65a9bf05dbdf6e4350ce21c3d520c16bfefe433"),
	DHTId(cast(ubyte[]) hexString!"b73502ae627deffa896a77455be794354b3119ca"),
	DHTId(cast(ubyte[]) hexString!"b790875844acaa8c1d67a2d85ccdd248bb2f9397"),
	DHTId(cast(ubyte[]) hexString!"b7aaa15fa4662bcbbdb042130ec02a2fe28fa07b"),
	DHTId(cast(ubyte[]) hexString!"b7c3c676582f556ad20efff1394671872676dc4e"),
	DHTId(cast(ubyte[]) hexString!"b80699a2c9215cebce2df2699c7e388bdb7a453e"),
	DHTId(cast(ubyte[]) hexString!"b822bae2096845fca775a8248ed771cb4a50fab7"),
	DHTId(cast(ubyte[]) hexString!"b83183606701c111aaf5f779eb9c6f6b8419cda3"),
	DHTId(cast(ubyte[]) hexString!"b8b0be9fade3ccca2081fa70b02dcaa0f5e9dbec"),
	DHTId(cast(ubyte[]) hexString!"b8d1bea40ea6a71b02b368c65bfc7937469cf3ff"),
	DHTId(cast(ubyte[]) hexString!"ba57f3edb099f4f410b242c7f42d130ffda1a705"),
	DHTId(cast(ubyte[]) hexString!"ba64389081eb7d0fd1ca46f9eb25597054f9a48e"),
	DHTId(cast(ubyte[]) hexString!"ba68126c3f9d5b56bcb5d6c82a5af6a17cd93017"),
	DHTId(cast(ubyte[]) hexString!"bbac23b59e757a2cfa530c568dc67945cc70e653"),
	DHTId(cast(ubyte[]) hexString!"bbea49e9eaac7d78cee5deeb468e368783d4e01e"),
	DHTId(cast(ubyte[]) hexString!"bd19709a48268a51c5393bd1066b0e8ef656662a"),
	DHTId(cast(ubyte[]) hexString!"bd44c786aa5d9f3acf06720b6d9208fb4920fe9b"),
	DHTId(cast(ubyte[]) hexString!"be062e3967422dd07ada5b87802698024da2d29b"),
	DHTId(cast(ubyte[]) hexString!"be84d76344ae26dc29ab9d169144dc4a38630ea1"),
	DHTId(cast(ubyte[]) hexString!"be914172d892b3ca5867fc1216e25a30e8a04e55"),
	DHTId(cast(ubyte[]) hexString!"bfa8031db547dde4526f91c89f8d3d0751792f3a"),
	DHTId(cast(ubyte[]) hexString!"bfe9060dc7f453f742b58c1f103b0d61f5d0e4de"),
	DHTId(cast(ubyte[]) hexString!"c146d8a5c9a657eba6cc7e8ec3a82fb8b28ad4d1"),
	DHTId(cast(ubyte[]) hexString!"c1ff0ec5ae9c6059a9ca685348ccc1cf85905271"),
	DHTId(cast(ubyte[]) hexString!"c27b3d473bbf502c79e7a455e6c0d36bd77ce077"),
	DHTId(cast(ubyte[]) hexString!"c283b88e85035b16b705020027936fa23e8f7091"),
	DHTId(cast(ubyte[]) hexString!"c29af8062e49aed005a6d057fd9b6f4700f6a08e"),
	DHTId(cast(ubyte[]) hexString!"c3412d64ef08cf1a700218aab675e350e5d475d5"),
	DHTId(cast(ubyte[]) hexString!"c372c540570738ddd0bbb685233ae7ee47ef5854"),
	DHTId(cast(ubyte[]) hexString!"c3769d462ceda7c757e6c731252c5124b490f0e0"),
	DHTId(cast(ubyte[]) hexString!"c388a78f357c70232ae3007d506bb6bc5cc43505"),
	DHTId(cast(ubyte[]) hexString!"c398ff26bb16139c53b039a985c053c62c34637f"),
	DHTId(cast(ubyte[]) hexString!"c3bf35b1479e019aa138f89ae252eb0e6b109bfc"),
	DHTId(cast(ubyte[]) hexString!"c3cabad79da4e79efbf0012f86dec8f11b0479b5"),
	DHTId(cast(ubyte[]) hexString!"c3d5d254eb5ad3970b326461255b0f5551864d37"),
	DHTId(cast(ubyte[]) hexString!"c5cb66973283b4872a7ae5d1214adb66be04c6ef"),
	DHTId(cast(ubyte[]) hexString!"c5e6e0b35369e9aa59626f74d38f67b90414189e"),
	DHTId(cast(ubyte[]) hexString!"c60b830599f18caf62181182b76bbbc67da36439"),
	DHTId(cast(ubyte[]) hexString!"c6a9f4c6421f8ba57c1a1645ad95c15c647d7901"),
	DHTId(cast(ubyte[]) hexString!"c777c633b29c882387e789b8686b179ff90b22d1"),
	DHTId(cast(ubyte[]) hexString!"c7f7828db57e41c62b1bfe87bc2f0c5f8cb738ba"),
	DHTId(cast(ubyte[]) hexString!"c8df00f83dd4203416641b65c8ed504c1ce17a0e"),
	DHTId(cast(ubyte[]) hexString!"c9293f8e5434220a9f0202fe3a60ae6ade2e514e"),
	DHTId(cast(ubyte[]) hexString!"c9654595270296c3c2406386d4cdf4795f04b3f0"),
	DHTId(cast(ubyte[]) hexString!"c9b29e3fe79f95c1389076e520ac2e04490d4aef"),
	DHTId(cast(ubyte[]) hexString!"c9d082493770735e4951ac8d213c3c304c863f1e"),
	DHTId(cast(ubyte[]) hexString!"cab53bbf61591376fd9c211646cfc99af61a4e6c"),
	DHTId(cast(ubyte[]) hexString!"cb17e8e28e4a6dbd95425259bbf0364cc3f04b97"),
	DHTId(cast(ubyte[]) hexString!"cc66f4d1fb2d800635da30ce109f447dd9af0bc9"),
	DHTId(cast(ubyte[]) hexString!"cc894d2d9f0434094970ce13275355f88006053e"),
	DHTId(cast(ubyte[]) hexString!"cede3d00a7501bf588090729110f6a4fe319ed2c"),
	DHTId(cast(ubyte[]) hexString!"cff71776e1e099d5b0512ed12a4e10ae21ac762a"),
	DHTId(cast(ubyte[]) hexString!"d0617449027719d7d0853004277e5c4786bfc65a"),
	DHTId(cast(ubyte[]) hexString!"d152b08bb1ba3f3ee95c196693e5e4b69fdbe04d"),
	DHTId(cast(ubyte[]) hexString!"d1cdf981561505f3b06120189b21039a33bd4a19"),
	DHTId(cast(ubyte[]) hexString!"d248f28ad03407d2b95e9fed3d476d67d8487bba"),
	DHTId(cast(ubyte[]) hexString!"d2dad2bf2a70c5bed17cdf555742c1020c8c025b"),
	DHTId(cast(ubyte[]) hexString!"d36a61a49ce2a88383209c1271acdb762e1c3bf7"),
	DHTId(cast(ubyte[]) hexString!"d42f2de1a15503a4f433cf46f445ba50824e424f"),
	DHTId(cast(ubyte[]) hexString!"d46e2d305269498cbe56fef9f93b9efbb8090f4c"),
	DHTId(cast(ubyte[]) hexString!"d4abefdf19c5a9ab73ced389faca97bdcbb2ef3f"),
	DHTId(cast(ubyte[]) hexString!"d5345554a8df61d26f35541831de895858c04192"),
	DHTId(cast(ubyte[]) hexString!"d6418262e8141d09009242078bd7f55ca0c8504d"),
	DHTId(cast(ubyte[]) hexString!"d6e8973eda204afa3bec90ba7a8ad60d10b46cdc"),
	DHTId(cast(ubyte[]) hexString!"d7fac7399f98c019764a67152fbf54cb22cf52ec"),
	DHTId(cast(ubyte[]) hexString!"d92b09d78a7ce43313d4342c39a586894bf89a14"),
	DHTId(cast(ubyte[]) hexString!"d9418e0d5508a556b9de0c6e7db32241434272b4"),
	DHTId(cast(ubyte[]) hexString!"d9614c8632585856cb3472d679fd4990083a2461"),
	DHTId(cast(ubyte[]) hexString!"d992da9fd068ec303fa707e1581fddb4505c50bb"),
	DHTId(cast(ubyte[]) hexString!"d9c241982dab2eead317235e7107559ac52ceed0"),
	DHTId(cast(ubyte[]) hexString!"da4229613c56b873f0377e0e45929e7baea3218f"),
	DHTId(cast(ubyte[]) hexString!"da99a6624a1064214d0df410d73a649d65312780"),
	DHTId(cast(ubyte[]) hexString!"dadff1f371d577eb13bfd6fb20261b20cfa41f7b"),
	DHTId(cast(ubyte[]) hexString!"db4394a2f0313e9e749be72b49a8c2b0ddf6e658"),
	DHTId(cast(ubyte[]) hexString!"db43d541402239af0794fea0b19ad184d9c180dc"),
	DHTId(cast(ubyte[]) hexString!"dbb42c1c09064f3131410b8f52f24226af838ad6"),
	DHTId(cast(ubyte[]) hexString!"dc27c2ced62bf631a39dbd58b8c74637ce2db119"),
	DHTId(cast(ubyte[]) hexString!"dca502e2fe385cc7c9e6c53618d5e55c5820a4b6"),
	DHTId(cast(ubyte[]) hexString!"dcb7efe95fb15aa5b543dcbd6d13e7e2dcde8320"),
	DHTId(cast(ubyte[]) hexString!"de680eab50c2e22edfbdee25411412879cf5b98a"),
	DHTId(cast(ubyte[]) hexString!"de692ba85a1121001449b5bc5878f7834948a481"),
	DHTId(cast(ubyte[]) hexString!"df7947b1ec0fbe3678aea2d0674fedffacb0005a"),
	DHTId(cast(ubyte[]) hexString!"df886694a3d811e5f11fdcbb081f3a4b765947b8"),
	DHTId(cast(ubyte[]) hexString!"e0d6fe727ede425e566b70fd3b3d9179e22c168b"),
	DHTId(cast(ubyte[]) hexString!"e1259dc9ed000626e06c677f3652956094f5681e"),
	DHTId(cast(ubyte[]) hexString!"e152f2d2522ee9eab0f50fa762552cf1c9f0d086"),
	DHTId(cast(ubyte[]) hexString!"e1ffb8aea7dcac1f6f3eb637e125c2d4b7f6be5f"),
	DHTId(cast(ubyte[]) hexString!"e2b150e872f3f98903ad65b77e8ea56095805a1f"),
	DHTId(cast(ubyte[]) hexString!"e32f791dc542c69f1fd8c8ded2d23e9d832a8e77"),
	DHTId(cast(ubyte[]) hexString!"e355364ebeb5838b27705c68f85b20a950110b8f"),
	DHTId(cast(ubyte[]) hexString!"e383bc311eaf73551a9e28cce19508d52ef3a798"),
	DHTId(cast(ubyte[]) hexString!"e50f395e5ea08e6bb2867860256dd3f9d0859b93"),
	DHTId(cast(ubyte[]) hexString!"e60a8164f10a94a470b43aec998f99e3ba6fee29"),
	DHTId(cast(ubyte[]) hexString!"e653d8cce0c51295d6cc18134f13e301c4ffd48d"),
	DHTId(cast(ubyte[]) hexString!"e68d6cfa8f95727ff75b04512f759c45f868337b"),
	DHTId(cast(ubyte[]) hexString!"e68e0cf7f6c13982eebd4964bc705e730f4eb19b"),
	DHTId(cast(ubyte[]) hexString!"e6ccef2c7415400e04244255d8a1d48e632f8ed9"),
	DHTId(cast(ubyte[]) hexString!"e71a9ca6fa4fd8742b1834f0e7c6f1baabb4f0d2"),
	DHTId(cast(ubyte[]) hexString!"e7584a575101a6bc4f92ff67a8f43c6cb73133a3"),
	DHTId(cast(ubyte[]) hexString!"e776d19aa1734d4174fb94511e14027f0d3ba84b"),
	DHTId(cast(ubyte[]) hexString!"e7a70a3483f38024442971647934ece8f03dcebc"),
	DHTId(cast(ubyte[]) hexString!"e7f43a5019009a77ce38c2cfb15696962dd7b91e"),
	DHTId(cast(ubyte[]) hexString!"e8a76cf9d8f3bcf4293a5a53e5c1314139d7ee1c"),
	DHTId(cast(ubyte[]) hexString!"e9a070c6d8de3332efca0cf90e7295be0632afc5"),
	DHTId(cast(ubyte[]) hexString!"e9ddf0edc2f04ecf98c25108b27bf5eeb26b13d0"),
	DHTId(cast(ubyte[]) hexString!"ea0c9ab847efa38a3699f03442d814273c66296f"),
	DHTId(cast(ubyte[]) hexString!"ea28c13d4e04cb7d53a859dbb47b25d4705ad62c"),
	DHTId(cast(ubyte[]) hexString!"ea5df1c968ab5f1658a4e9cd2e15d4eddeefed1e"),
	DHTId(cast(ubyte[]) hexString!"ea924204aabf1e4b60106d23eb56b2bff08cbe90"),
	DHTId(cast(ubyte[]) hexString!"eb2f856d929e124bf1fd298095e99083b726e08b"),
	DHTId(cast(ubyte[]) hexString!"eb78a366c6e9f513af5a744e94c0d156c8a692b3"),
	DHTId(cast(ubyte[]) hexString!"eb815fb408ec9ff4f0fc38a63a461c61f8eddbb7"),
	DHTId(cast(ubyte[]) hexString!"ec7bc89224cf085b72b189c91bf591dd6e30437f"),
	DHTId(cast(ubyte[]) hexString!"ecd7dc98ee811c409684dab3ba45666d7320bf71"),
	DHTId(cast(ubyte[]) hexString!"ed3b84e777f823c6a625739cc4fcb5e92996cbbd"),
	DHTId(cast(ubyte[]) hexString!"ed6007b8cd1f2efee257b00f829a26f372f8bbd1"),
	DHTId(cast(ubyte[]) hexString!"edef172e2bd4d155d1ad0531cccc22ac39b977ab"),
	DHTId(cast(ubyte[]) hexString!"edf2e0024765392c518df916c6882884e5f1c21a"),
	DHTId(cast(ubyte[]) hexString!"ee3973e4b8baa604d5a5d0d54007c88fe8e678c6"),
	DHTId(cast(ubyte[]) hexString!"eff64c9d27332054112405897710c51bb3dbb6dd"),
	DHTId(cast(ubyte[]) hexString!"f045972760e7537e3d8794c90480ad3be3408ece"),
	DHTId(cast(ubyte[]) hexString!"f092b5fa9f01dee17dd40b75f91b85f46a38227c"),
	DHTId(cast(ubyte[]) hexString!"f0af5ed0371b600f27c8ea71829acd92c3edacb8"),
	DHTId(cast(ubyte[]) hexString!"f1eddeff9b08e8ec98da7a7f2606df1cbc5e5b91"),
	DHTId(cast(ubyte[]) hexString!"f205f6e9084f0fdfdb6ed295c8035ab7b318049d"),
	DHTId(cast(ubyte[]) hexString!"f340889c57f605fced067f4199a19e556fb5bdf1"),
	DHTId(cast(ubyte[]) hexString!"f466b2c94d0c34355a6a5e94936c0cfeb1928ca7"),
	DHTId(cast(ubyte[]) hexString!"f48897808742dd0f03d3104fc8003376822993ed"),
	DHTId(cast(ubyte[]) hexString!"f50ae543e2f5068427ae2b25660127be545c8fe6"),
	DHTId(cast(ubyte[]) hexString!"f5346bd1b1170a92d05befa38804a2b41ec2f9d3"),
	DHTId(cast(ubyte[]) hexString!"f5fce91cfbfcd98710066cb1d81e6a2fa42ed594"),
	DHTId(cast(ubyte[]) hexString!"f765c30eb5d2286868339ea3910d540f85e161f1"),
	DHTId(cast(ubyte[]) hexString!"f7e8b42b20b33134341f40515dccfec99c291894"),
	DHTId(cast(ubyte[]) hexString!"f812600bbbb39d34e95d93d838a75de32f9dee87"),
	DHTId(cast(ubyte[]) hexString!"f84736dbdf4eac539b89c931377570214addb838"),
	DHTId(cast(ubyte[]) hexString!"f90d06bed3d6107434beb5e346033a47f91a694c"),
	DHTId(cast(ubyte[]) hexString!"fa1c953d59f6f37216f7b6e28d9ae563a0213919"),
	DHTId(cast(ubyte[]) hexString!"fa2587fbae917c1eb6e001db013666c46b93e0c7"),
	DHTId(cast(ubyte[]) hexString!"fabd998228b4391a9fab390e0577e31087d75705"),
	DHTId(cast(ubyte[]) hexString!"fadaa68cffbfef1a829cd2264d8e390c147e4e30"),
	DHTId(cast(ubyte[]) hexString!"fb419c9f27be619dabff5ff7208c953b71ee2f00"),
	DHTId(cast(ubyte[]) hexString!"fbbb26deca055c46dacbe4787ede135b816534f8"),
	DHTId(cast(ubyte[]) hexString!"fc7b0f917b2100ca0756e9c75cd23c5c7b3e1fe0"),
	DHTId(cast(ubyte[]) hexString!"fcbafe423d8e603b15af2d2286db1ca09007c6a6"),
	DHTId(cast(ubyte[]) hexString!"fd5a8fcca11b27544465458251e2e2762db055b1"),
	DHTId(cast(ubyte[]) hexString!"fd5fdf21aef4505451861da97aa39000ed852988"),
	DHTId(cast(ubyte[]) hexString!"fdf95ee34994a19a25cc6f06562adee1cf73518e"),
	DHTId(cast(ubyte[]) hexString!"fe48e91b5baf63a0b5c4232b44c23516d5d1190b"),
	DHTId(cast(ubyte[]) hexString!"fe977c5905a13f27b1ba0d35b7d0951859eb82c7"),
	DHTId(cast(ubyte[]) hexString!"feb08ad55ec7a163080bbf824f8ea94b325cd5b0"),
	DHTId(cast(ubyte[]) hexString!"ffb43a937778e59de615037bb5a68e142db43717"),
];


