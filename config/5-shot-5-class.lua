
return function(opt)
   opt.nClasses = {train=5, val=5, test=5}
   --opt.nClasses = 5
   opt.nTrainShot = 5
   opt.nEval = 15
   
   opt.nTest = 100
   opt.nTestShot = {1,5}

   return opt
end