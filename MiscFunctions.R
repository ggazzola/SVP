
CreateFolds = function (y, k = 10) # borrowed and slightly modified from caret package
{
	list = TRUE
	if(k<2)
		stop("k must be at least 2\n")

	if(is.data.frame(y)) {
		if(ncol(y)==1)
			y = y[,1]
		else
			stop("Something is wrong with y\n")
	} 

    if (is.numeric(y)) {
        cuts <- floor(length(y)/k)
        if (cuts < 2) 
            cuts <- 2
        if (cuts > 5) 
            cuts <- 5
        breaks <- unique(quantile(y, probs = seq(0, 1, length = cuts)))
        y <- cut(y, breaks, include.lowest = TRUE)
    }
    if (k < length(y)) {
        y <- factor(as.character(y))
        numInClass <- table(y)
        foldVector <- vector(mode = "integer", length(y))
        for (i in 1:length(numInClass)) {
            min_reps <- numInClass[i]%/%k
            if (min_reps > 0) {
                spares <- numInClass[i]%%k
                seqVector <- rep(1:k, min_reps)
                if (spares > 0) 
                  seqVector <- c(seqVector, sample(1:k, spares))
                foldVector[which(y == names(numInClass)[i])] <- sample(seqVector)
            }
            else {
                foldVector[which(y == names(numInClass)[i])] <- sample(1:k, 
                  size = numInClass[i])
            }
        }
    } else foldVector <- seq(along = y)
    if (list) {
        outIdx <- split(seq(along = y), foldVector)
        names(outIdx) <- paste("Fold", gsub(" ", "0", format(seq(along = outIdx))), 
            sep = "")
		inIdx = outIdx
            inIdx <- lapply(inIdx, function(data, y) y[-data], y = seq(along = y))
		res = list(train=inIdx, test=outIdx)
    }
    else res <- foldVector
    res
}

PcBBUncertainty = function(overallPCConstraintsFullOut, subsetPCConstraintsFullOut, datMiss, maxUncertainDims, propIn){
	# "all" means we always consider the overall dimensionality of datMiss as the maximum in which uncertainty can take place
	# as opposed to that of the actual uncertain dimensions on datMiss
	# overallPCConstraintsFullOut: PC bb enclosing all data points in datMiss (e.g., considering the median imputation of datMiss) 
	# in the subspace of missing dimensions of a given point 
	# subsetPCConstraintsFullOut: PC bb enclosing uncertainty of the above point in the subspace of missing dimensions of that point
	#
	stopifnot(is.matrix(datMiss))
	stopifnot((is.character(maxUncertainDims) & maxUncertainDims=="all") | is.null(maxUncertainDims))
	
	datMissP = ncol(datMiss)
	if (maxUncertainDims=="all"){
		maxUncertainDims = datMissP
	} else{
		minDat = apply(datMiss, 2, min)
		maxDat = apply(datMiss, 2, max)
		maxUncertainDims = sum((maxDat-minDat)>0)
	}
	
	overall = overallPCConstraintsFullOut
	subset = subsetPCConstraintsFullOut
	stopifnot(overall$volumeDims == subset$volumeDims)
	stopifnot(overall$volumeDims%in%(1:datMissP))
	if(propIn>0){
		stopifnot(sum(subset$length!=0)==length(overall$volumeDims))
		stopifnot((subset$length!=0) == (overall$length!=0))
		meanLengthSubset = mean(subset$length[subset$length!=0]) # mean length of the sides of the PC-bb enclosing the point's uncertainty
	} else{
		meanLengthSubset = 0
	}
	meanLengthOverall = mean(overall$length[overall$length!=0]) # mean length of the sides of the PC-bb enclosing all data points
	
	res = min(meanLengthSubset/meanLengthOverall*length(subset$volumeDims)/maxUncertainDims,1) #ratio between lengths, reweighted by 
							# ratio of the number of  uncertain dimensions in the point over the total number of dimensions (or over the number of missing dimensions in the overall data )
	return(res)
}

Which.min.tie = function (x) {
	# Same as which.min, but breaks ties randomly
	# x: vector of numeric values
	y <- seq_along(x)[x == min(x)]
	if (length(y) > 1L) 
		sample(y, 1L)
	else y
}

PolytopeDescription = function(constraintOut, hyperRectangle = T){
	resList = list()
	stopifnot(!is.null(constraintOut$lhs))
	stopifnot(!is.null(constraintOut$rhs))
	stopifnot(!is.null(constraintOut$dir))
	stopifnot(!is.null(constraintOut$volumeDims))
	stopifnot(!is.null(constraintOut$volume)) # assume this should be non-null even if not available
	stopifnot(!is.null(constraintOut$length))
	
	resList$A = constraintOut$lhs
	resList$a = constraintOut$rhs
	resList$dir = constraintOut$dir
	resList$volumeDims = constraintOut$volumeDims
	if(hyperRectangle) {
		resList$volume = constraintOut$volume
		resList$length = constraintOut$length
	} else{
		resList$volume = Volume(A,a)
	}
	return(resList)
	
}

PasteFast = function(vect) {
	#bare-bone version of R's paste function, with sep and collapse set to "",
	#vect is a numerical vector (but the function also works if vect is a character vector)
	
	#vect <- list(c("R", vect))

	.Internal(paste(list(vect), "", ""))
}

ImputDistribution = function(originalDat, missingDat, imputedDatList){
	#returns distribution of imputations for every pair of missing variables of a data set
	#originalDat: the matrix of original "true" data (with no missing values)
	#missingDat: the same as originalDat, but with missing values
	#imputedDatList: a list, with element i of which being the i-th matrix of multiple imputations 
	
	#res[[i]] corresponds to a specific pairwise variable combination ($missingI and $missingJ)
	#if res[[i]]$dat is an empty list, then there are no observations in missingDat that have
	# both missing value along i and along j
	#res[[i]]$dat[[k]] corresponds to the k-th observation that shows up in missingDat with missing values
	# on both i and j, with $original being the corresponding original observation in originalDat,
	# $imputations being the corresponding imputations in imputedDatList, $cor being the correlation between
	# the imputed values along i and those along j for and $MAEI/$MAEJ being the mean absolute error of the imputations
	# along i/j with respect to the true value, which will be used to define res[[i]]$corVect/$maeI/$maeJ (one 
	# element for each observation k in res[[i]])
	
	
	p = ncol(missingDat)
	res = list()
	cnt = 1
	for(i in 1:(p-1)){
		for(j in (i+1):p){
			whichMissIJ = which(is.na(missingDat[,i]) & is.na(missingDat[,j]))
			res[[cnt]] = list(missingI = i, missingJ = j, dat=list())
			cnt2 = 1
			corVect =  maeIVect = maeJVect = NULL
			if(length(whichMissIJ)>0){
				for(k in whichMissIJ){
					originalDatWithMissIJ = originalDat[k, c(i,j)]
					imputedDatWithMissIJMat  = NULL
					for(l in 1:length(imputedDatList))
						imputedDatWithMissIJMat = rbind(imputedDatWithMissIJMat, imputedDatList[[l]][k, c(i,j)])
				
					res[[cnt]]$dat[[cnt2]]=list()
					res[[cnt]]$dat[[cnt2]]$original = originalDatWithMissIJ
					res[[cnt]]$dat[[cnt2]]$imputations = imputedDatWithMissIJMat
					res[[cnt]]$dat[[cnt2]]$cor = cor(imputedDatWithMissIJMat[,1], imputedDatWithMissIJMat[,2])
					res[[cnt]]$dat[[cnt2]]$MAEI = mean(abs(imputedDatWithMissIJMat[,1] - originalDatWithMissIJ[1]))
					res[[cnt]]$dat[[cnt2]]$MAEJ = mean(abs(imputedDatWithMissIJMat[,2] - originalDatWithMissIJ[2]))
					corVect = c(corVect, res[[cnt]]$dat[[cnt2]]$cor)
					maeIVect = c(maeIVect, res[[cnt]]$dat[[cnt2]]$MAEI)
					maeJVect = c(maeJVect, res[[cnt]]$dat[[cnt2]]$MAEJ)
					cnt2 = cnt2+1
				}
				res[[cnt]]$corVect = corVect
				res[[cnt]]$maeIVect = maeIVect
				res[[cnt]]$maeJVect = maeJVect
				
			}
			cnt = cnt +1
		
		}
	}
	return(res)	
}

CorToCovMat = function(corMat, stdVect){
	stopifnot(is.matrix(corMat))
	stopifnot(is.numeric(stdVect))
	stopifnot(all(stdVect>=0))
	stopifnot(ncol(corMat)==ncol(corMat))
	stopifnot(ncol(corMat)==length(stdVect))
	covMat=corMat
	for(i in 1:nrow(corMat))
		for(j in 1:ncol(corMat))
			covMat[i, j] = corMat[i, j] *stdVect[i]*stdVect[j]
	return(covMat)		
}

ScaleCenter=function(obj, scaleMean, scaleSd) {
	restore=is.vector(obj)
	obj=VectToMat(obj)
	obj=sweep(obj,2,scaleMean)
	obj=sweep(obj,2,scaleSd, "/")
	if(restore) 
		obj=as.numeric(obj)
		
	return(obj)
}

VectToMat=function(dat, byRow=T) {
	if(is.vector(dat) & !is.data.frame(dat)){
		output=as.matrix(dat)
		if(byRow)
			output=t(output)
	} else {
		output=dat
	}
	return(output)
}

GetSolution = function(model, gurobiOut, what="w", datRowIndex="all"){
	#model is, e.g., the output of PolytopeSVR
	#gurobiOut is the output of a gurobi call
	#what is the name of the variables we want to get the value of
	#if what is 'u' or 'v', datRowIndex is the index of the data point whose corresponding 
	# u / v variables we want to get the value of
	
	stopifnot(!is.null(model$varIdx))
	stopifnot(is.list(model))
	stopifnot(is.list(gurobiOut))
	stopifnot(is.character(what))
	stopifnot(!is.null(gurobiOut$x))
	solution = gurobiOut$x
	if(is.list(model$varIdx[[what]])){
		if(is.numeric(datRowIndex)){
			stopifnot(length(datRowIndex)==1)
			res = solution[model$varIdx[[what]][[datRowIndex]]]
		} else {
			res = solution[unlist(model$varIdx[[what]])] # returning variable values for all data points
		}
	} else{
		res = solution[model$varIdx[[what]]]
	}
	return(res)	
}

TheoXYCorCov = function(beta, betaNoise, CovMat) {
	# Returns vector theoXYCorVect of theoretical linear correlation between each of X_1, X_2, ..., X_p and Y,
	# 	vector theoXYCovVect of theoretical covariance between each of X_1, X_2, ..., X_p and Y,
	#	and theoretical standard deviation of Y (?it looks like it's that of X)
	# assuming:
	# 1) Y = beta[1]* X_1 + beta[2]*X_2 + ... + beta[p]*X_p + betaNoise*Eps
	# 2) all X_j's and Eps are ***standard*** normal -- (LOOKS LIKE ALL WE ACTUALLY ASSUME IS VAR(EPS)=1!!)
	# 3) Eps is independent of all of X_1, X_2, ..., X_p
	# beta is the vector of theoretical regression coefficients
	# betaNoise is the theoretical regression coefficient associated to Eps,
	#	i.e., the variance of the noise component in the RHS is betaNoise^2
	# CovMat is the theoretical covariance matrix of X_1, X_2, ..., X_p
	
	p = length(beta)
	theoXSumVar = 0
	theoXYCovVect = numeric(p) 
	for(a in 1:p) 
		for(b in 1:p) 
			theoXSumVar = theoXSumVar +beta[a]*beta[b]*CovMat[a,b] # variance of the sum of X_1, X_2, ..., X_p
	
	theoYStdev = sqrt(theoXSumVar + betaNoise^2) # standard deviation of Y (betaNoise^2 is the variance of Eps)
	for(a in 1:p)
		theoXYCovVect[a] = CovMat[a,]%*%beta # Cov(X_a, Y) # since Cov(X_a, Eps) = 0, Cov(X_a, Y) = Cov(X_a, Y-Eps), where Y-Eps is the noise-free output
	
	theoXStdevVect = sqrt(diag(CovMat))
	theoXYCorVect = theoXYCovVect/(theoXStdevVect*theoYStdev)
	res = list(theoXYCorVect = theoXYCorVect, theoXYCovVect = theoXYCovVect, theoXSumVar = theoXSumVar, theoXStdevVect = theoXStdevVect)
	return(res)
}

CalibrateBetaNoise = function(theoXYCovVect, theoXSumVar, theoXStdevVect, CovMat, desiredRsq) {
	# returns the value of betaNoise necessary to obtain a theoretical Rsq equal to desiredRsq
	# theoXYCovVect, theoXSumVar are obtained from a call to TheoXYCorCov with any betaNoise
	# 	since they are independent of betaNoise itself
	# CovMat should be the same as inputted in TheoXYCorCov
	
	precision = 32 # to avoid res to be the square root of a negative number if desiredRsq =1
					# in case of numerical micro errors in the calculation of gamma
	gamma = t(theoXYCovVect/(theoXStdevVect)^2)%*%solve(CovMat)%*%(theoXYCovVect/(theoXStdevVect)^2)
	gamma = round(gamma, precision)
	theoXSumVar = round(theoXSumVar, precision)
	res = as.numeric(sqrt(gamma/desiredRsq-theoXSumVar))
	return(res)
}

TheoRSquared = function(theoXYCorVect, CovMat) {
	# returns the theoretical R^2 of linear model
	# Y = beta[1]* X_1 + beta[2]*X_2 + ... + beta[p]*X_p + betaNoise*Eps,
	# with the same assumption as in TheoCor
	# theoXYCorVect and theoXStdevVect are from the output of a TheoXYCorCov call
	# CovMat should be the same as inputted in TheoXYCorCov
	rsq = as.numeric(t(theoXYCorVect)%*%solve(CovMat)%*%theoXYCorVect)
	return(rsq)
}

NoiseLevel = function(beta, CovMat, desiredRsq) {
	TheoXYCorCovOut = TheoXYCorCov(beta, betaNoise = 0, CovMat)
	theoXYCovVect = TheoXYCorCovOut$theoXYCovVect
	theoXSumVar = TheoXYCorCovOut$theoXSumVar
	theoXStdevVect = TheoXYCorCovOut$theoXStdevVect
	betaNoiseVal = CalibrateBetaNoise(theoXYCovVect, theoXSumVar, theoXStdevVect , CovMat, desiredRsq)
	return(betaNoiseVal)
}

MAE = function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	res = mean(abs(trueY-predY))
	return(res)
}

RMSE = function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	res = sqrt(mean((trueY-predY)^2))
	return(res)
}

MaxAE =  function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	res = max(abs(trueY-predY))
	return(res)
}

QuantNineAE =  function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	
	res = as.numeric(quantile(abs(trueY-predY),.9))
	return(res)
}

QuantEightAE =  function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	
	res = as.numeric(quantile(abs(trueY-predY),.8))
	return(res)
}

QuantSevenAE =  function(trueY, predY, toInclude=rep(T, length(predY))) {
	stopifnot(length(trueY)==length(predY))
	stopifnot(length(trueY)==length(toInclude))
	stopifnot(is.logical(toInclude))
	if(sum(toInclude)==0)
		return(Inf)
	trueY = trueY[toInclude]
	predY = predY[toInclude]
	
	res = as.numeric(quantile(abs(trueY-predY),.7))
	return(res)
}

#dims = 12
#Cov <- matrix(0, dims, dims) 
#Cov[1:4,1:4] = 0.9
#diag(Cov)[] <- 1

#beta = c(5,5,2,0,-5,-5,-2,0, 0, 0, 0, 0)

#desiredRsq = 0.69
#TheoXYCorCovOut = TheoXYCorCov(beta, betaNoise = 0, Cov)
#theoXYCovVect = TheoXYCorCovOut$theoXYCovVect
#theoXSumVar = TheoXYCorCovOut$theoXSumVar
#theoXStdevVect = TheoXYCorCovOut$theoXStdevVect
#betaNoiseVal = CalibrateBetaNoise(theoXYCovVect, theoXSumVar, theoXStdevVect , Cov, desiredRsq)

#TheoXYCorCovOut = TheoXYCorCov(beta, betaNoise = betaNoiseVal, Cov)
#theoXYCorVect = TheoXYCorCovOut$theoXYCorVect

#resultingRsq = TheoRSquared(theoXYCorVect, Cov)

#nPts = 100000
#X = mvrnorm(nPts, rep(0, nrow(Cov)), Sigma = Cov)
#cleanY = X%*%beta
#Y = cleanY + rnorm(nPts, 0, betaNoiseVal)
#(cor(cleanY, Y))^2