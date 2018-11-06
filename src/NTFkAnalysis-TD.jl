import TensorDecompositions
import NMFk

DMAXITER = 1000

function analysis(X::AbstractArray{T,N}, dsizes::Vector{Int64}, dim, nTF; kw...) where {T,N}
	csize = collect(size(X))
	ndimensons = length(csize)
	sizes = Vector{Tuple}(0)
	for i in dsizes
		nt = ntuple(k->(k == dim ? i : csize[k]), ndimensons)
		push!(sizes, nt)
	end
	info("Sizes: $(sizes)")
	analysis(X, sizes, nTF; kw...)
end

"""
methods: spnntucker, tucker_als, tucker_sym
"""
function analysis(X::AbstractArray{T,N}, csize::NTuple{N,Int}=size(X), nTF::Integer=1; clusterdim::Integer=1, resultdir::String=".", prefix::String="spnn", seed::Integer=0, tol::Number=1e-8, ini_decomp=:hosvd, core_nonneg=true, verbose=false, max_iter::Integer=DMAXITER, lambda::Number=0.1, lambdas=fill(lambda, length(size(X)) + 1), eigmethod=trues(N), progressbar::Bool=false, quiet::Bool=true, serial::Bool=false, saveall::Bool=false) where {T,N}
	info("TensorDecompositions Tucker analysis with core size $(csize)...")
	info("Clustering Dimension: $clusterdim")
	@assert clusterdim <= N || clusterdim > 1
	seed > 0 && srand(seed)
	tsize = size(X)
	ndimensons = length(tsize)
	info("Tensor size: $(tsize)")
	residues = Vector{Float64}(nTF)
	tsi = Vector{TensorDecompositions.Tucker{T,N}}(nTF)
	WBig = Vector{Matrix}(nTF)
	nans = isnan.(X)
	if sum(nans) > 0
		warn("The tensor has NaN's; they will be zeroed temporarily.")
		X[nans] .= 0
	end
	tsbest = nothing
	# lambdas = convert(Vector{T}, lambdas)
	if nprocs() > 1 && !serial
		tsi = pmap(i->(srand(seed+i); TensorDecompositions.spnntucker(X, csize; eigmethod=eigmethod, tol=tol, ini_decomp=ini_decomp, core_nonneg=core_nonneg, verbose=verbose, max_iter=max_iter, lambdas=lambdas, progressbar=false)), 1:nTF)
	else
		for n = 1:nTF
			@time tsi[n] = TensorDecompositions.spnntucker(X, csize; eigmethod=eigmethod, tol=tol, ini_decomp=ini_decomp, core_nonneg=core_nonneg, verbose=verbose, max_iter=max_iter, lambdas=lambdas, progressbar=progressbar)
		end
	end
	for n = 1:nTF
		residues[n] = TensorDecompositions.rel_residue(tsi[n], X)
		println("$(n): relative residual $(residues[n])")
		normalizecore!(tsi[n])
		f = tsi[n].factors[clusterdim]'
		# f[f.==0] = max(minimum(f), 1e-6)
		# p = NTFk.plotmatrix(cpi[n].factors[1]')
		# display(p); println()
		# p = NTFk.plotmatrix(f)
		# display(p); println()
		# @show minimum(cpi[n].lambdas), maximum(cpi[n].lambdas)
		WBig[n] = hcat(f)
	end
	minsilhouette = nTF > 1 ? clusterfactors(WBig, quiet) : NaN
	imin = indmin(residues)
	X_esta = TensorDecompositions.compose(tsi[imin])
	correlations = mincorrelations(X_esta, X)
	# NTFk.atensor(tsi[imin].core)
	csize_new = TensorToolbox.mrank(tsi[imin].core)
	println("$(csize): relative residual $(residues[imin]) worst tensor correlations $(correlations) rank $(csize_new) silhouette $(minsilhouette)")
	if saveall
		recursivemkdir(resultdir; filename=false)
		recursivemkdir(prefix; filename=false)
		JLD.save("$(resultdir)/$(prefix)-$(mapsize(csize))->$(mapsize(csize_new)).jld", "t", tsi[imin])
	end

	if sum(nans) > 0
		X[nans] .= NaN
	end

	return tsi[imin], residues[imin], correlations, minsilhouette
end

function analysis(X::AbstractArray{T,N}, csizes::Vector{NTuple{N,Int}}, nTF::Integer=1; clusterdim::Integer=1, resultdir::String=".", prefix::String="spnn", serial::Bool=false, seed::Integer=0, kw...) where {T,N}
	info("TensorDecompositions Tucker analysis for a series of $(length(csizes)) core sizes ...")
	warn("Clustering Dimension: $clusterdim")
	recursivemkdir(resultdir; filename=false)
	recursivemkdir(prefix; filename=false)
	@assert clusterdim <= N || clusterdim > 1
	seed > 0 && srand(seed)
	tsize = size(X)
	ndimensons = length(tsize)
	nruns = length(csizes)
	residues = Vector{T}(nruns)
	correlations = Array{T}(nruns, ndimensons)
	tucker_spnn = Vector{TensorDecompositions.Tucker{T,N}}(nruns)
	minsilhouette = Vector{T}(nruns)
	if nprocs() > 1 && !serial
		r = pmap(i->(srand(seed+i); analysis(X, csizes[i], nTF; clusterdim=clusterdim, resultdir=resultdir, prefix=prefix, kw..., serial=true, quiet=true)), 1:nruns)
		tucker_spnn = map(i->(r[i][1]), 1:nruns)
		residues = map(i->(r[i][2]), 1:nruns)
		correlations = map(i->(r[i][3]), 1:nruns)
		minsilhouette = map(i->(r[i][4]), 1:nruns)
	else
		s = nprocs() > 1 ? false : true
		for i in 1:nruns
			tucker_spnn[i], residues[i], correlations[i,:], minsilhouette[i] = analysis(X, csizes[i], nTF; clusterdim=clusterdim, resultdir=resultdir, prefix=prefix, serial=s, kw...)
		end
	end
	info("Decompositions (clustering dimension: $clusterdim)")
	ibest = 1
	best = Inf
	for i in 1:nruns
		if residues[i] < best
			best = residues[i]
			ibest = i
		end
	end
	for i in 1:nruns
		println("$i - $(csizes[i]): residual $(residues[i]) worst tensor correlations $(correlations[i,:]) rank $(TensorToolbox.mrank(tucker_spnn[i].core)) silhouette $(minsilhouette[i])")
	end
	# NTFk.atensor(tucker_spnn[ibest].core)
	csize = TensorToolbox.mrank(tucker_spnn[ibest].core)
	info("Estimated true core size based on the reconstruction: $(csize)")
	JLD.save("$(resultdir)/$(prefix)-$(mapsize(csize)).jld", "t", tucker_spnn)
	return tucker_spnn, csize, ibest
end

"""
methods: ALS, SGSD, cp_als, cp_apr, cp_nmu, cp_opt, cp_sym, cp_wopt
"""
function analysis(X::AbstractArray{T,N}, trank::Integer, nTF=1; seed::Number=-1, tol=1e-8, verbose=false, max_iter=DMAXITER, method=:ALS, resultdir::String=".", prefix::String="$(string(method))", quiet=true, serial::Bool=false, saveall=false, kw...) where {T,N}
	if contains(string(method), "cp_")
		info("MATLAB TensorToolbox CanDecomp analysis using $(string(method)) ...")
	elseif contains(string(method), "bcu_")
		info("MATLAB Block-coordinate nonconvex CanDecomp analysis using $(string(method)) ...")
	else
		info("TensorDecompositions CanDecomp analysis using $(string(method)) ...")
	end
	recursivemkdir(resultdir; filename=false)
	recursivemkdir(prefix; filename=false)
	seed >= 0 && srand(seed)
	tsize = size(X)
	ndimensons = length(tsize)
	info("CP core rank: $(trank)")
	residues = Array{T}(nTF)
	cpi = Array{TensorDecompositions.CANDECOMP{T,N}}(nTF)
	WBig = Vector{Matrix}(nTF)
	cpbest = nothing
	if nprocs() > 1 && !serial
		cpi = pmap(i->(srand(seed+i); NTFk.candecomp(X, trank; verbose=verbose, maxiter=max_iter, method=method, tol=tol, kw...)), 1:nTF)
	else
		for n = 1:nTF
			@time cpi[n] = NTFk.candecomp(X, trank; verbose=verbose, maxiter=max_iter, method=method, tol=tol, kw...)
		end
	end
	for n = 1:nTF
		residues[n] = TensorDecompositions.rel_residue(cpi[n], X)
		normalizelambdas!(cpi[n])
		f = map(k->cpi[n].factors[k]', 1:ndimensons)
		# p = NTFk.plotmatrix(cpi[n].factors[1]')
		# display(p); println()
		# p = NTFk.plotmatrix(f)
		# display(p); println()
		# @show minimum(cpi[n].lambdas), maximum(cpi[n].lambdas)
		WBig[n] = hcat(f...)
	end
	minsilhouette = nTF > 1 ? clusterfactors(WBig, quiet) : NaN
	imin = indmin(residues)
	csize = length(cpi[imin].lambdas)
	X_esta = TensorDecompositions.compose(cpi[imin])
	correlations = mincorrelations(X_esta, X)
	println("$(trank): residual $(residues[imin]) worst tensor correlations $(correlations) rank $(csize) silhouette $(minsilhouette)")
	saveall && JLD.save("$(resultdir)/$(prefix)-$(mapsize(csize)).jld", "t", cpi[imin])
	return cpi[imin], residues[imin], correlations, minsilhouette
end

function analysis(X::AbstractArray{T,N}, tranks::Vector{Int}, nTF=1; seed::Number=-1, method=:ALS, resultdir::String=".", prefix::String="$(string(method))", serial::Bool=false, kw...) where {T,N}
	seed >= 0 && srand(seed)
	recursivemkdir(resultdir; filename=false)
	recursivemkdir(prefix; filename=false)
	tsize = size(X)
	ndimensons = length(tsize)
	nruns = length(tranks)
	residues = Array{T}(nruns)
	correlations = Array{T}(nruns, ndimensons)
	cpf = Array{TensorDecompositions.CANDECOMP{T,N}}(nruns)
	minsilhouette = Array{Float64}(nruns)
	if nprocs() > 1 && !serial
		r = pmap(i->(srand(seed+i); analysis(X, tranks[i], nTF; method=method, resultdir=resultdir, prefix=prefix, kw..., serial=true, quiet=true)), 1:nruns)
		cpf = map(i->(r[i][1]), 1:nruns)
		residues = map(i->(r[i][2]), 1:nruns)
		correlations = map(i->(r[i][3]), 1:nruns)
		minsilhouette = map(i->(r[i][4]), 1:nruns)
	else
		s = nprocs() > 1 ? false : true
		for i in 1:nruns
			cpf[i], residues[i], correlations[i, :], minsilhouette[i] = analysis(X, tranks[i], nTF; method=method, resultdir=resultdir, prefix=prefix, serial=s, kw...)
		end
	end
	info("Decompositions:")
	ibest = 1
	best = Inf
	for i in 1:nruns
		if residues[i] < best
			best = residues[i]
			ibest = i
		end
		println("$i - $(tranks[i]): residual $(residues[i]) worst tensor correlations $(correlations[i,:]) silhouette $(minsilhouette[i])")
	end
	csize = length(cpf[ibest].lambdas)
	info("Estimated true core size: $(csize)")
	JLD.save("$(resultdir)/$(prefix)-$(csize).jld", "t", cpf)
	return cpf, csize, ibest
end

function clusterfactors(W, quiet)
	clusterassignments, M = NMFk.clustersolutions(W)
	if !quiet
		info("Cluster assignments:")
		display(clusterassignments)
		info("Cluster centroids:")
		display(M)
	end
	_, clustersilhouettes, _ = NMFk.finalize(W, clusterassignments)
	if !quiet
		info("Silhouettes for each of the $(length(clustersilhouettes)) clusters:" )
		display(clustersilhouettes')
		println("Mean silhouette = ", mean(clustersilhouettes))
		println("Min  silhouette = ", minimum(clustersilhouettes))
	end
	return minimum(clustersilhouettes)
end

function getsizes(csize::Tuple, tsize::Tuple=csize .+ 1)
	ndimensons = length(tsize)
	@assert ndimensons == length(csize)
	sizes = [csize]
	for i = 1:ndimensons
		nt = ntuple(k->(k == i ? min(tsize[i], csize[i] + 1) : csize[k]), ndimensons)
		addsize = true
		for j = 1:length(sizes)
			if sizes[j] == nt
				addsize = false
				break
			end
		end
		addsize && push!(sizes, nt)
		nt = ntuple(k->(k == i ? max(1, csize[i] - 1) : csize[k]), ndimensons)
		addsize = true
		for j = 1:length(sizes)
			if sizes[j] == nt
				addsize = false
				break
			end
		end
		addsize && push!(sizes, nt)
	end
	return sizes
end

function atensor(X::Union{TensorDecompositions.Tucker,TensorDecompositions.CANDECOMP})
	atensor(TensorDecompositions.compose(X))
end

function atensor(X::Array)
	nd = ndims(X)
	info("Number of dimensions: $nd")
	tsize = size(X)
	mask = Vector{Vector{Bool}}(nd)
	for i = 1:nd
		info("D$i ($(tsize[i]))")
		mask[i] = trues(tsize[i])
		for j = 1:tsize[i]
			st = ntuple(k->(k == i ? j : Colon()), nd)
			if nd == 3
				r = rank(X[st...])
			else
				r = TensorToolbox.mrank(X[st...])
			end
			z = count(X[st...] .> 0)
			println("$j : rank $r non-zeros $z")
			if z == 0
				mask[i][j] = false
			end
			# display(X[st...])
		end
	end
	return mask
end

function normalizefactors!(X::TensorDecompositions.Tucker{T,N}, order=1:N; check::Bool=false) where {T,N}
	check && (Xi = TensorDecompositions.compose(X))
	l = size(X.core)
	for i = order
		m = maximum(X.factors[i], 1)
		@assert length(m) == l[i]
		for j = 1:l[i]
			ind = map(k->((i==k) ? j : Colon()), 1:N)
			X.core[ind...] .*= m[j]
		end
		m[m.==0] = 1.0
		X.factors[i] ./= m
	end
	if check
		Xe = TensorDecompositions.compose(X)
		info("Normalization error: $(vecnorm(Xi .- Xe))")
	end
	return nothing
end

function normalizecore!(X::TensorDecompositions.Tucker{T,N}, order=1:N; check::Bool=false) where {T,N}
	check && (Xi = TensorDecompositions.compose(X))
	l = size(X.core)
	v = collect(1:N)
	for i = order
		m = vec(maximum(X.core, v[v.!=i]))
		X.factors[i] .*= m'
		m[m.==0] = 1.0
		for j = 1:l[i]
			ind = map(k->((i==k) ? j : Colon()), 1:N)
			X.core[ind...] ./= m[j]
			# @show m[j]
		end
		m = vec(maximum(X.core, v[v.!=i]))
	end
	if check
		Xe = TensorDecompositions.compose(X)
		info("Normalization error: $(vecnorm(Xi .- Xe))")
	end
	return nothing
end

function normalizefactors!(X::TensorDecompositions.CANDECOMP{T,N}, order=1:N; check::Bool=false) where {T,N}
	check && (Xi = TensorDecompositions.compose(X))
	for i = order
		m = maximum(X.factors[i], 1)
		X.lambdas .*= vec(m)
		m[m.==0] = 1.0
		X.factors[i] ./= m
	end
	if check
		Xe = TensorDecompositions.compose(X)
		info("Normalization error: $(vecnorm(Xi .- Xe))")
	end
	return nothing
end

function normalizelambdas!(X::TensorDecompositions.CANDECOMP{T,N}, order=1:N; check::Bool=false) where {T,N}
	check && (Xi = TensorDecompositions.compose(X))
	m = vec(X.lambdas)' .^ (1/N)
	for i = order
		X.factors[i] .*= m
	end
	m = copy(X.lambdas)
	m[m.==0] = 1.0
	X.lambdas ./= m
	if check
		Xe = TensorDecompositions.compose(X)
		info("Normalization error: $(vecnorm(Xi .- Xe))")
	end
	return nothing
end

function mincorrelations(X1::AbstractArray{T,N}, X2::AbstractArray{T,N}) where {T,N}
	if N == 3
		tsize = size(X1)
		@assert tsize == size(X2)
		c = Vector{T}(N)
		c[1] = minimum(map(j->minimum(map(k->corinf(X1[:,k,j], X2[:,k,j]), 1:tsize[2])), 1:tsize[3]))
		c[2] = minimum(map(j->minimum(map(k->corinf(X1[k,:,j], X2[k,:,j]), 1:tsize[1])), 1:tsize[3]))
		c[3] = minimum(map(j->minimum(map(k->corinf(X1[k,j,:], X2[k,j,:]), 1:tsize[1])), 1:tsize[2]))
		return c
	else
		warn("Minimum correlations can be computed for 3 dimensional tensors only; D=$N")
		return NaN
	end
end

function corinf(v1::Vector{T}, v2::Vector{T}) where {T}
	c = abs.(cor(v1, v2))
	c = isnan(c) ? Inf : c
end