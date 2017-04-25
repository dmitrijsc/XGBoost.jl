function train(params::Dict{String,<:Any}, dtrain::DMatrix;
               num_boost_round::Int = 10,
               evals::Vector{Tuple{DMatrix,String}} = Vector{Tuple{DMatrix,String}}(),
               obj::Union{Function,Void} = nothing, feval::Union{Function,Void} = nothing,
               maximize::Bool = false, early_stopping_rounds::Union{Int,Void} = nothing,
               verbose_eval::Union{Bool,Int} = true,
               xgb_model::Union{Booster,String,Void} = nothing,
               callbacks::Union{Vector{Function},Void} = nothing)

    callbacks_vec = isa(callbacks, Vector{Function}) ? callbacks : Vector{Function}()

    if isa(verbose_eval, Bool) && verbose_eval == true
        push!(callbacks_vec, cb_print_evaluation())
    elseif isa(verbose_eval, Int)
        push!(callbacks_vec, cb_print_evaluation(verbose_eval))
    end

    if !isa(early_stopping_rounds, Void)
        push!(callbacks_vec, cb_early_stop(early_stopping_rounds, maximize, verbose_eval, params,
                                           evals, feval)) # TODO: Add "early_stopping_metric"
    end

    # Initialize the Booster with the appropriate caches.
    if isa(xgb_model, Void)
        cache = unshift!([eval[1] for eval in evals], dtrain)
        bst = Booster(params = params, cache = cache)
        num_boost = 0
    else
        if isa(xgb_model, String)
            _xgb_model = xgb_model
        else isa(xgb_model, Booster)
            _xgb_model = save_raw(xgb_model)
        end
        cache = unshift!([eval[1] for eval in evals], dtrain)
        bst = Booster(params = params, cache = cache;
                      model_file = _xgb_model)
        num_boost = length(get_dump(bst))
    end

    if haskey(params, "num_parallel_tree")
        num_parallel_tree = params["num_parallel_tree"]
        num_boost /= num_parallel_tree
    else
        num_parallel_tree = 1
    end

    if haskey(params, "num_class")
        num_boost /= params["num_class"]
    end

    # Add distributed code support.
    rank = 0
    start_iteration = 1

    callbacks_before_iter = [cb for cb in callbacks_vec if cb.cb_timing == "before"]
    callbacks_after_iter = [cb for cb in callbacks_vec if cb.cb_timing == "after"]

    results = init_results(evals)
    env = CallbackEnv(bst, CVPack[], 0, start_iteration, num_boost_round, rank, results)

    for iter in start_iteration:num_boost_round
        env.iteration = iter
        for cb in callbacks_before_iter
            cb(env)
        end

        update(bst, dtrain, iter, fobj = obj)
        num_boost += 1
        # Add distributed code support.

        if length(evals) > 0
            evalstring = eval_set(bst, evals, iter, feval = feval)
            row = 1 + iter - start_iteration
            num_rows = 1 + num_boost_round - start_iteration
            insert_evals!(results, evalstring, row, 1, num_rows, 1)
        end

        try
            for cb in callbacks_after_iter
                cb(env)
            end
        catch err
            if isa(err, EarlyStopException)
                break
            else
                rethrow(err)
            end
        end
        # Add distributed code
    end

    # if attr(bst, "best_score") != ""
    #     bst.best_score = float(attr(bst, "best_score"))
    #     bst.best_iteration = parse(Int, attr(bst, "best_iteration"))
    # else
    #     bst.best_iteration = num_boost - 1
    # end
    # bst.best_ntree_limit = (bst.best_iteration + 1) * num_parallel_tree

    return bst
end


# Return a results dictionary with a dictionary entry for each eval_name.
function init_results(evals::Vector{Tuple{DMatrix,String}})
    results = Dict(i[2] => Dict{String,Matrix{Float64}}() for i in evals)
    return results
end


# Insert the entries in the evalstring into the results dictionary.
function insert_evals!(results::Dict{String,Dict{String,Matrix{Float64}}}, evalstring::String,
                       row::Int, col::Int, num_rows::Int, num_cols::Int)
    split_eval_set = split(evalstring, ['\t', '-', ':'], keep = false)
    num_evals = div(length(split_eval_set) + 1, 3)

    for eval_idx in 1:num_evals
        eval_name_idx = 2 + 3 * (eval_idx - 1)
        eval_name = split_eval_set[eval_name_idx]
        metric_name = split_eval_set[eval_name_idx + 1]
        metric_value = split_eval_set[eval_name_idx + 2]

        curr_eval = results[eval_name]
        if !haskey(curr_eval, metric_name)
            curr_eval[metric_name] = Matrix{Float64}(num_rows, num_cols)
        end

        curr_eval[metric_name][row] = float(metric_value)
    end

    return results
end


### train ###
function xgboost(data, nrounds::Integer;
                 label = nothing, param::Dict{String,<:Any} = Dict{String,String}(),
                 watchlist = [], metrics = [],
                 obj = nothing, feval = nothing, group = [], kwargs...)
    if isa(data, DMatrix)
        dtrain = data
    else
        dtrain = DMatrix(data, label = label)
    end

    if length(group) > 0
      set_info(dtrain, "group", group)
    end

    cache = [dtrain]
    for itm in watchlist
        push!(cache, itm[1])
    end
    bst = Booster(cache = cache)
    XGBoosterSetParam(bst.handle, "silent", "1")
    silent = false
    for itm in kwargs
        XGBoosterSetParam(bst.handle, string(itm[1]), string(itm[2]))
        if itm[1] == :silent
            silent = itm[2] != 0
        end
    end
    for itm in param
        XGBoosterSetParam(bst.handle, string(itm[1]), string(itm[2]))
    end
    if size(watchlist)[1] == 0
        watchlist = [(dtrain, "train")]
    end
    for itm in metrics
        XGBoosterSetParam(bst.handle, "eval_metric", string(itm))
    end
    for i in 1:nrounds
        update(bst, dtrain, i, fobj = obj)
        if !silent
            println(eval_set(bst, watchlist, i, feval = feval))
        end
    end
    return bst
end


type CVPack
    dtrain::DMatrix
    dtest::DMatrix
    watchlist::Vector{Tuple{DMatrix,String}}
    bst::Booster

    function CVPack(dtrain::DMatrix, dtest::DMatrix, param)
        bst = Booster(cache = [dtrain, dtest])
        for itm in param
            XGBoosterSetParam(bst.handle, string(itm[1]), string(itm[2]))
        end
        watchlist = [(dtrain, "train"), (dtest, "test")]
        new(dtrain, dtest, watchlist, bst)
    end
end


function mknfold(dall::DMatrix, nfold::Integer, param, seed::Integer, evals=[]; fpreproc = nothing,
                 kwargs = [])
    srand(seed)
    randidx = randperm(XGDMatrixNumRow(dall.handle))
    kstep = size(randidx)[1] / nfold
    idset = [randidx[round(Int64, (i-1) * kstep) + 1 : min(size(randidx)[1],round(Int64, i * kstep))] for i in 1:nfold]
    ret = CVPack[]
    for k in 1:nfold
        selected = Int[]
        for i in 1:nfold
            if k != i
                selected = vcat(selected, idset[i])
            end
        end
        dtrain = slice(dall, selected)
        dtest = slice(dall, idset[k])
        if isa(fpreproc, Function)
            dtrain, dtest, tparam = fpreproc(dtrain, dtest, deepcopy(param))
        else
            tparam = param
        end
        plst = vcat([itm for itm in param], [("eval_metric", itm) for itm in evals])
        plst = vcat(plst, [(string(itm[1]), string(itm[2])) for itm in kwargs])
        push!(ret, CVPack(dtrain, dtest, plst))
    end
    return ret
end


function aggcv(rlist; show_stdv = true)
    cvmap = Dict()
    ret = split(rlist[1])[1]
    for line in rlist
        arr = split(line)
        @assert ret == arr[1]
        for it in arr[2:end]
            k, v  = split(it, ":")
            if !haskey(cvmap, k)
                cvmap[k] = Float64[]
            end
            push!(cvmap[k], float(v))
        end
    end
    items = [item for item in cvmap]
    sort!(items, by = x -> x[1])
    for item in items
        k = item[1]
        v = item[2]
        if show_stdv == true
            ret *= @sprintf("\tcv-%s:%f+%f", k, mean(v), std(v))
        else
            ret *= @sprintf("\tcv-%s:%f", k, mean(v))
        end
    end
    return ret
end


function nfold_cv(data, num_boost_round::Integer = 10, nfold::Integer = 3; label = nothing,
                  param = [], metrics = [], obj = nothing, feval = nothing, fpreproc = nothing,
                  show_stdv = true, seed::Integer = 0, kwargs...)
    if isa(data, DMatrix)
        dtrain = data
    else
        dtrain = DMatrix(data, label = label)
    end

    results = String[]
    cvfolds = mknfold(dtrain, nfold, param, seed, metrics, fpreproc = fpreproc, kwargs = kwargs)
    for i in 1:num_boost_round
        for f in cvfolds
            update(f.bst, f.dtrain, i, fobj = obj)
        end
        res = aggcv([eval_set(f.bst, f.watchlist, i, feval = feval) for f in cvfolds],
                    show_stdv = show_stdv)
        push!(results, res)
        println(res)
    end
end


immutable FeatureImportance
    fname::String
    gain::Float64
    cover::Float64
    freq::Float64
end


function Base.show(io::IO, f::FeatureImportance)
    @printf(io, "%s: gain = %0.04f, cover = %0.04f, freq = %0.04f", f.fname, f.gain, f.cover,
            f.freq)
end


function Base.show(io::IO, arr::Vector{FeatureImportance}; maxrows = 30)
    println(io, "$(length(arr))-element Vector{$(FeatureImportance)}:")
    println(io, "Gain      Coverage  Frequency  Feature")
    for i in 1:min(maxrows, length(arr))
        @printf(io, "%0.04f    %0.04f    %0.04f     %s\n", arr[i].gain, arr[i].cover, arr[i].freq,
                arr[i].fname)
    end
end


Base.show(io::IO, ::MIME"text/plain", arr::Vector{FeatureImportance}) = show(io, arr)


function importance(bst::Booster; fmap::String = "")
    data = XGBoosterDumpModel(bst.handle, fmap, 1)

    # get the total gains for each feature and the whole model
    gains = Dict{String,Float64}()
    covers = Dict{String,Float64}()
    freqs = Dict{String,Float64}()
    totalGain = 0.
    totalCover = 0.
    totalFreq = 0.
    lineMatch = r"^[^\w]*[0-9]+:\[([^\]]+)\] yes=([\.+e0-9]+),no=([\.+e0-9]+),[^,]*,?gain=([\.+e0-9]+),cover=([\.+e0-9]+).*"
    nameStrip = r"[<>][^<>]+$"
    for i in 1:length(data)
        for line in split(unsafe_string(data[i]), '\n')
            m = match(lineMatch, line)
            if !isa(m, Void)
                fname = replace(m.captures[1], nameStrip, "")

                gain = parse(Float64, m.captures[4])
                totalGain += gain
                gains[fname] = get(gains, fname, 0.) + gain

                cover = parse(Float64, m.captures[5])
                totalCover += cover
                covers[fname] = get(covers, fname, 0.) + cover

                totalFreq += 1
                freqs[fname] = get(freqs, fname, 0.) + 1
            end
        end
    end

    # compile these gains into list of features sorted by gain value
    res = FeatureImportance[]
    for fname in keys(gains)
        push!(res, FeatureImportance(fname,
                                     gains[fname] / totalGain,
                                     covers[fname] / totalCover,
                                     freqs[fname] / totalFreq))
    end
    sort!(res, by = x -> -x.gain)
end


function importance(bst::Booster, feature_names::Vector{String})
    res = importance(bst)

    result = FeatureImportance[]
    for old_importance in res
        actual_name = feature_names[parse(Int64, old_importance.fname[2:end]) + 1]
        push!(result, FeatureImportance(actual_name, old_importance.gain, old_importance.cover,
                                        old_importance.freq))
    end

    return result
end
