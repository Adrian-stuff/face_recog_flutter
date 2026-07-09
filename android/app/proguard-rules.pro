# tflite_flutter references the optional GPU delegate reflectively; this
# app doesn't bundle GPU delegate support (falls back to CPU inference),
# so the class is legitimately absent — silence R8's missing-class error.
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
