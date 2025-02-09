using MeshArrays, MITgcmTools, OceanStateEstimation
using CSV, DataFrames, Statistics, Plots
#using FortranFiles, 

import Plots: heatmap

"""
    heatmap(x::MeshArray; args...)

Apply heatmap to each subdomain in a MeshArray    
"""
function heatmap(x::MeshArray; args...)
    n=x.grid.nFaces
    p=()
    for i=1:n; p=(p...,heatmap(x[i]; args...)); end
    plot(p...)
end

#Convert Velocity (m/s) to transport (m^3/s)
function convert_velocities(U::MeshArray,V::MeshArray,G::NamedTuple)
    for i in eachindex(U)
        tmp1=U[i]; tmp1[(!isfinite).(tmp1)] .= 0.0
        tmp1=V[i]; tmp1[(!isfinite).(tmp1)] .= 0.0
        U[i]=G.DRF[i[2]]*U[i].*G.DYG[i[1]]
        V[i]=G.DRF[i[2]]*V[i].*G.DXG[i[1]]
    end
    return U,V
end

##

"""
    trsp_read(myspec::String,mypath::String)

Function that reads files that were generated by `trsp_prep`
"""
function trsp_read(myspec::String,mypath::String)
    γ=GridSpec(myspec,mypath)
    TrspX=γ.read(mypath*"TrspX.bin",MeshArray(γ,Float32))
    TrspY=γ.read(mypath*"TrspY.bin",MeshArray(γ,Float32))
    TauX=γ.read(mypath*"TauX.bin",MeshArray(γ,Float32))
    TauY=γ.read(mypath*"TauY.bin",MeshArray(γ,Float32))
    SSH=γ.read(mypath*"SSH.bin",MeshArray(γ,Float32))
    return TrspX, TrspY, TauX, TauY, SSH
end

"""
    trsp_prep(γ,Γ,dirOut)

Function that generates small binary files (2D) from large netcdf ones (4D).

```
using FortranFiles, MeshArrays
!isdir("nctiles_climatology") ? error("missing files") : nothing
include(joinpath(dirname(pathof(MeshArrays)),"gcmfaces_nctiles.jl"))
(TrspX, TrspY, TauX, TauY, SSH)=trsp_prep(γ,Γ,MeshArrays.GRID_LLC90);
```
"""
function trsp_prep(γ::gcmgrid,Γ::NamedTuple,dirOut::String="")

    #wind stress
    fileName="nctiles_climatology/oceTAUX/oceTAUX"
    oceTAUX=read_nctiles(fileName,"oceTAUX",γ)
    fileName="nctiles_climatology/oceTAUY/oceTAUY"
    oceTAUY=read_nctiles(fileName,"oceTAUY",γ)
    oceTAUX=mask(oceTAUX,0.0)
    oceTAUY=mask(oceTAUY,0.0)

    #sea surface height anomaly
    fileName="nctiles_climatology/ETAN/ETAN"
    ETAN=read_nctiles(fileName,"ETAN",γ)
    fileName="nctiles_climatology/sIceLoad/sIceLoad"
    sIceLoad=read_nctiles(fileName,"sIceLoad",γ)
    rhoconst=1029.0
    myssh=(ETAN+sIceLoad./rhoconst)
    myssh=mask(myssh,0.0)

    #seawater transports
    fileName="nctiles_climatology/UVELMASS/UVELMASS"
    U=read_nctiles(fileName,"UVELMASS",γ)
    fileName="nctiles_climatology/VVELMASS/VVELMASS"
    V=read_nctiles(fileName,"VVELMASS",γ)
    U=mask(U,0.0)
    V=mask(V,0.0)

    #time averaging and vertical integration
    TrspX=similar(Γ.DXC)
    TrspY=similar(Γ.DYC)
    TauX=similar(Γ.DXC)
    TauY=similar(Γ.DYC)
    SSH=similar(Γ.XC)

    for i=1:γ.nFaces
        tmpX=mean(U.f[i],dims=4)
        tmpY=mean(V.f[i],dims=4)
        for k=1:length(Γ.RC)
            tmpX[:,:,k]=tmpX[:,:,k].*Γ.DYG.f[i]
            tmpX[:,:,k]=tmpX[:,:,k].*Γ.DRF[k]
            tmpY[:,:,k]=tmpY[:,:,k].*Γ.DXG.f[i]
            tmpY[:,:,k]=tmpY[:,:,k].*Γ.DRF[k]
        end
        TrspX.f[i]=dropdims(sum(tmpX,dims=3),dims=(3,4))
        TrspY.f[i]=dropdims(sum(tmpY,dims=3),dims=(3,4))
        TauX.f[i]=dropdims(mean(oceTAUX.f[i],dims=3),dims=3)
        TauY.f[i]=dropdims(mean(oceTAUY.f[i],dims=3),dims=3)
        SSH.f[i]=dropdims(mean(myssh.f[i],dims=3),dims=3)
    end

    if !isempty(dirOut)
        write_bin(TrspX,dirOut*"TrspX.bin")
        write_bin(TrspY,dirOut*"TrspY.bin")
        write_bin(TauX,dirOut*"TauX.bin")
        write_bin(TauY,dirOut*"TauY.bin")
        write_bin(SSH,dirOut*"SSH.bin")
    end

    return TrspX, TrspY, TauX, TauY, SSH
end

"""
    trsp_prep(γ,Γ,dirOut)

Function that writes a `MeshArray` to a binary file using `FortranFiles`.
"""
function write_bin(inFLD::MeshArray,filOut::String)
    recl=prod(inFLD.grid.ioSize)*4
    tmp=Float32.(convert2gcmfaces(inFLD))
    println("saving to file: "*filOut)
    f =  FortranFile(filOut,"w",access="direct",recl=recl,convert="big-endian")
    write(f,rec=1,tmp)
    close(f)
end

##

"""
    rotate_uv(uv,γ)

    1. Convert to `Sv` units and mask out land
    2. Interpolate `x/y` transport to grid cell center
    3. Convert to `Eastward/Northward` transport
    4. Display Subdomain Arrays (optional)
"""
function rotate_uv(uv::Dict,G::NamedTuple)
    u=1e-6 .*uv["U"]; v=1e-6 .*uv["V"];
    u[findall(G.hFacW[:,1].==0)].=NaN
    v[findall(G.hFacS[:,1].==0)].=NaN;

    nanmean(x) = mean(filter(!isnan,x))
    nanmean(x,y) = mapslices(nanmean,x,dims=y)
    (u,v)=exch_UV(u,v); uC=similar(u); vC=similar(v)
    for iF=1:u.grid.nFaces
        tmp1=u[iF][1:end-1,:]; tmp2=u[iF][2:end,:]
        uC[iF]=reshape(nanmean([tmp1[:] tmp2[:]],2),size(tmp1))
        tmp1=v[iF][:,1:end-1]; tmp2=v[iF][:,2:end]
        vC[iF]=reshape(nanmean([tmp1[:] tmp2[:]],2),size(tmp1))
    end

    cs=G.AngleCS
    sn=G.AngleSN
    u=uC.*cs-vC.*sn
    v=uC.*sn+vC.*cs;

    return u,v,uC,vC
end

"""
    interp_uv(u,v)
"""
function interp_uv(u,v)
    mypath=MeshArrays.GRID_LLC90
    SPM,lon,lat=read_SPM(mypath) #interpolation matrix (sparse)
    uI=MatrixInterp(write(u),SPM,size(lon)) #interpolation itself
    vI=MatrixInterp(write(v),SPM,size(lon)); #interpolation itself
    return transpose(uI),transpose(vI),vec(lon[:,1]),vec(lat[1,:])
end
