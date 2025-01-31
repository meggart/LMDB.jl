mutable struct LMDBDict{K,V}
    env::LMDB.Environment
    dbi::LMDB.DBI
    function LMDBDict{K,V}(env::LMDB.Environment, dbi::LMDB.DBI) where {K,V}
        x = new{K,V}(env, dbi)
        finalizer(x) do d
            LMDB.close(d.env,d.dbi)
            LMDB.close(d.env)
        end
        x
    end
end
function LMDBDict{K,V}(path::String; readonly = false) where {K,V} 
    flags = readonly ? MDB_RDONLY : zero(Cuint)
    env = LMDB.create()
    open(env, path)
    #A transaction just for getting a DBI handle
    dbi = LMDB.start(env,flags=flags) do txn
        LMDB.open(txn)
    end
    LMDBDict{K,V}(env, dbi)
end
LMDBDict(path::String; kwargs...) = LMDBDict{String, Vector{Uint8}}(path; kwargs...)


function cursor_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    LMDB.start(d.env, flags = txnflags) do txn
        LMDB.open(txn,d.dbi) do cur
            f(cur)
        end
    end
end

function txn_dbi_do(f, d; readonly = false)
    txnflags = readonly ? Cuint(LMDB.MDB_RDONLY) : Cuint(0)
    LMDB.start(d.env, flags = txnflags) do txn
        f(txn, d.dbi)
    end
end

function list_dirs(d::LMDBDict{String}; prefix = "", sep = '/')
    cursor_do(d, readonly = true) do cur
        bprefix = Vector{UInt8}(prefix)
        iter = LMDB.LMDBIterator(cur,LMDB.DirectoryLister(;sep = sep, lprefix = length(bprefix)),bprefix)
        collect(iter)
    end
end

function Base.keys(d::LMDBDict{K}; prefix=UInt8[]) where K
    cursor_do(d, readonly = true) do cur
        collect(keys(cur,K,prefix=prefix))
    end
end

function Base.values(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    cursor_do(d, readonly = true) do cur
        collect(values(cur,V,prefix=prefix))
    end
end

function Base.collect(d::LMDBDict{K,V}; prefix=UInt8[]) where {K,V}
    cursor_do(d, readonly = true) do cur
        collect((LMDB.LMDBIterator(cur,LMDB.ReturnBoth{K,V}(),Vector{UInt8}(prefix))))
    end
end

function valuesize(d::LMDBDict; prefix = UInt8[])
    cursor_do(d, readonly = true) do cur
        iter = LMDB.LMDBIterator(cur,LMDB.ReturnValueSize(),Vector{UInt8}(prefix))
        sum(iter)
    end
end

function Base.getindex(d::LMDBDict{K,V},k) where {K,V}
    cursor_do(d, readonly = true) do cur
        LMDB.get(cur, k, V, LMDB.MDB_SET_KEY)
    end
end

function Base.haskey(d::LMDBDict{K}, key) where K
    txn_dbi_do(d, readonly = true) do txn, dbi
        mdb_key_ref = Ref(MDBValue(toref(key)))
        mdb_val_ref = Ref(MDBValue())
        @show key
        # Get value
        ret = _mdb_get(txn.handle, dbi.handle, mdb_key_ref, mdb_val_ref)
        if ret == MDB_NOTFOUND
            return false
        elseif ret == Cint(0)
            return true
        else
            throw(LMDB.LMDBError(ret))
        end
    end
end

function Base.setindex!(d::LMDBDict{K,V},v,k) where {K,V}
    txn_dbi_do(d) do txn, dbi
        LMDB.put!(txn,dbi,k,v)
    end
    v
end

function Base.delete!(d::LMDBDict{K},k) where K
    txn_dbi_do(d) do txn, dbi
        LMDB.delete!(txn, dbi, k)
    end
    d
end