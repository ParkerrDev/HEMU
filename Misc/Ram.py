import struct

MAGIC=b"HMRAM001"
PAGE=64


def Pack(ram):
    if len(ram)!=402653184:
        raise ValueError("Invalid native RAM size")
    runs=[]
    for off in range(0,len(ram),PAGE):
        if any(ram[off:off+PAGE]):
            if runs and runs[-1][1]==off:
                runs[-1][1]+=PAGE
            else:
                runs.append([off,off+PAGE])
    return (MAGIC+struct.pack("<II",len(ram),len(runs))+
        b"".join(struct.pack("<II",a,b-a) for a,b in runs)+
        b"".join(ram[a:b] for a,b in runs))


def Expand(data):
    if len(data)<16 or data[:8]!=MAGIC:
        raise ValueError("Invalid packed RAM header")
    size,count=struct.unpack_from("<II",data,8)
    if size!=402653184 or count>size//PAGE or 16+8*count>len(data):
        raise ValueError("Invalid packed RAM dimensions")
    ram=bytearray(size);at=16+8*count;end=0
    for i in range(count):
        start,length=struct.unpack_from("<II",data,16+8*i)
        if not length or start%PAGE or length%PAGE or start<end or start+length>size or at+length>len(data):
            raise ValueError("Invalid packed RAM range")
        ram[start:start+length]=data[at:at+length]
        at+=length;end=start+length
    if at!=len(data):
        raise ValueError("Unexpected packed RAM data")
    return ram


if __name__=="__main__":
    import gzip
    import sys
    from pathlib import Path
    Path(sys.argv[2]).write_bytes(Expand(gzip.decompress(Path(sys.argv[1]).read_bytes())))
