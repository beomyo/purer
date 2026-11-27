# cf https://developer.android.com/topic/performance/app-optimization/add-keep-rules

# The upstream gallery app kept the whole metadata/TIFF/mp4parser libraries
# because local-file decoding looked classes up dynamically. This app only
# decodes remote images (Flutter engine) and remote video frames (platform
# media stack), so those libraries are no longer reachable and R8 can shrink
# them. Keep rules were removed on purpose.

# referenced from: com.google.crypto.tink
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
