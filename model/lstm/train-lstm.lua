local t = require 'torch'
local autograd = require 'autograd'
local nn = require 'nn'
local util = require 'cortex-core.projects.research.oneShotLSTM.util.util'
local _ = require 'moses'

--require 'cortex-core.projects.research.oneShotLSTM.model.lstm.lstm-helper'
require 'cortex-core.projects.research.oneShotLSTM.model.lstm.meta-learner-lstm'
require 'cortex-core.projects.research.oneShotLSTM.model.lstm.learning-to-learn-model'

return function(opt, dataset)
   -- data
   local metaTrainSet = dataset.train
   local metaValidationSet = dataset.validation
   local metaTestSet = dataset.test
 
   -- keep track of errors
   local avgs = {} 
   local trainConf = optim.ConfusionMatrix(opt.nClasses.train)
   local valConf = {}
   local testConf = {}
   for _,k in pairs(opt.nTestShot) do
      valConf[k] = optim.ConfusionMatrix(opt.nClasses.val)
      testConf[k] = optim.ConfusionMatrix(opt.nClasses.test)
      avgs[k] = 0 
   end 

   -- learner
   local learner = getLearner(opt)  
   print("Learner nParams: " .. learner.nParams)   

   -- meta-learner (our lstm or learning-to-learn?)   
   local metaLearnerF 
   if opt.version == 1 then
      metaLearnerF = getMetaLearner1
   elseif opt.version == 2 then 
      metaLearnerF = getMetaLearner2
   end
   local metaLearner = metaLearnerF({learnerParams=learner.params, nParams=learner.nParams, debug=opt.debug, homePath=opt.homePath, steps=opt.steps, BN1=opt.BN1, BN2=opt.BN2})  

   -- type of classification (use network or nearest-neighbor?)
   local classify 
   if opt.classify == 'network' then
      classify = metaLearner.f 
   elseif opt.classify == 'nearest-neighbor' then
      classify = metaLearner.nearestNeighbor
   end
   
   -- load params from file?
   if opt.metaLearnerParamsFile then
      print('loading from: ' .. opt.metaLearnerParamsFile)
      metaLearner.params = torch.load(opt.metaLearnerParamsFile)
   end

   -- cast params to float or cuda 
   local cast = "float"
   if opt.useCUDA then
      cast = "cuda"
   end
   metaLearner.params = autograd.util.cast(metaLearner.params, cast)
   print("Meta-learner params")
   print(metaLearner.params)        

   local nEpisode = opt.nEpisode
   local cost = 0
   local timer = torch.Timer()
   local printPer = opt.printPer 
   local evalCounter = 1
   local prevIterParams

   local lstmState = {{},{}}

   -- init optimizer
   local optimizer, optimState = autograd.optim[opt.optimMethod](metaLearner.dfWithGradNorm, tablex.deepcopy(opt), metaLearner.params) 

   for d=1,nEpisode do  
      -- create training epsiode 
      local trainSet, testSet = metaTrainSet.createEpisode({nTrain=opt.nShot, nClasses=opt.nClasses})   
   
      -- train and test
      local trainData = trainSet:get() 
      local trainInput, trainTarget = util.extractK(trainData.input, trainData.target, opt.nTrainShot, opt.nClasses.train)
      local testData = testSet:get()
   
      local gParams, loss, prediction = optimizer(learner, trainInput, trainTarget, testData.input, testData.target, opt.nEpochs[opt.nTrainShot], opt.batchSize[opt.nTrainShot])
      cost = cost + loss      
      
      for i=1,prediction:size(1) do
         trainConf:add(prediction[i], testData.target[i])   
      end

      -- validation status
      if math.fmod(d, printPer) == 0 then
         local elapsed = timer:time().real
         print(string.format("Dataset: %d, Train Loss: %.3f, LR: %.3f, Time: %.4f s", d, cost/(printPer), util.getCurrentLR(optimState[1]), elapsed))
         print(trainConf)
         trainConf:zero()

         -- validation loop   
         for v=1,opt.nValidationEpisode do
            local trainSet, testSet = metaValidationSet.createEpisode({})
            local trainData = trainSet:get()
            local testData = testSet:get()
            
            -- k-shot loop
            for _,k in pairs(opt.nTestShot) do
               local trainInput, trainTarget = util.extractK(trainData.input, trainData.target, k, opt.nClasses.val)
   
               local _, prediction = classify(metaLearner.params, learner, trainInput, trainTarget, testData.input, testData.target, opt.nEpochs[k], opt.batchSize[k])     
      
               for i=1,prediction:size(1) do
                  valConf[k]:add(prediction[i], testData.target[i])  
               end

            end
         end   
      
         for _,k in pairs(opt.nTestShot) do 
            print('Validation accuracy (' .. k .. '-shot)')
            print(valConf[k])
            valConf[k]:zero()
         end
   
         cost = 0
         timer = torch.Timer() 
      end

      if math.fmod(d, 1000) == 0 then
         local prevIterParams = util.deepClone(metaLearner.params)   
         torch.save("metaLearner_params_snapshot.th", autograd.util.cast(prevIterParams, "float"))
      end   
   end

   -- test loop
   for d=1,opt.nTest do 
      local trainSet, testSet = metaTestSet.createEpisode({nTrain=opt.nShot, nClasses=opt.nClasses})   

      local trainData = trainSet:get() 
      local testData = testSet:get()
      local loss, prediction 

      -- k-shot loop
      for _, k in pairs(opt.nTestShot) do 
         local trainInput, trainTarget = util.extractK(trainData.input, trainData.target, k, opt.nClasses.test)

         local _, prediction = classify(metaLearner.params, learner, trainInput, trainTarget, testData.input, testData.target, opt.nEpochs[k], opt.batchSize[k])  
         
         for i=1,prediction:size(1) do
            testConf[k]:add(prediction[i], testData.target[i]) 
         end

      end
         
   end

   for _,k in pairs(opt.nTestShot) do 
      print('Test Accuracy (' .. k .. '-shot)')
      print(testConf[k])
   end

   return _.values(_.map(testConf, function(i,cM) 
            return i .. '-shot: ' .. cM.totalValid*100
          end))
end