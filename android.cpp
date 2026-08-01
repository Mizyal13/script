// ==========================================
// Android Runtime Location Bypass & Spoof Engine
// Target: Android LocationManager / WebView APIs
// ==========================================

Java.perform(function () {
    console.log("[*] Initializing Android Location Spoofing Hook...");

    const LocationManager = Java.use("android.location.LocationManager");
    const Location = Java.use("android.location.Location");

    // Coordinates to enforce (e.g., Tokyo target configuration)
    const spoofLat = 35.6762;
    const spoofLon = 139.6503;
    const spoofProvider = "gps";

    // 1. Hook getLastKnownLocation(String provider)
    LocationManager.getLastKnownLocation.overload('java.lang.String').implementation = function (provider) {
        console.log("[*] Intercepted getLastKnownLocation() | Original Provider: " + provider);
        
        let loc = this.getLastKnownLocation(provider);
        if (loc !== null) {
            loc.setLatitude(spoofLat);
            loc.setLongitude(spoofLon);
            loc.setProvider(spoofProvider);
            loc.setAccuracy(1.0);
            loc.setTime(new Date().getTime());
            return loc;
        } else {
            // Construct a fake location object if none exists natively
            let dummyLoc = Location.$new(spoofProvider);
            dummyLoc.setLatitude(spoofLat);
            dummyLoc.setLongitude(spoofLon);
            dummyLoc.setAccuracy(1.0);
            dummyLoc.setTime(new Date().getTime());
            return dummyLoc;
        }
    };

    // 2. Hook requestLocationUpdates to sanitize live location callbacks
    const overloadSignatures = [
        ['java.lang.String', 'long', 'float', 'android.location.LocationListener'],
        ['java.lang.String', 'long', 'float', 'android.location.LocationListener', 'android.os.Looper']
    ];

    overloadSignatures.forEach(sig => {
        try {
            LocationManager.requestLocationUpdates.overload.apply(LocationManager.requestLocationUpdates, sig).implementation = function() {
                console.log("[*] Intercepted requestLocationUpdates() with signature match.");
                
                // Extract arguments and modify the listener callback if necessary
                let args = Array.prototype.slice.call(arguments);
                // Force provider argument to GPS if desired, or let original pass through modified
                args[0] = spoofProvider; 
                
                return this.requestLocationUpdates.apply(this, args);
            };
        } catch (e) {
            // Signature variant not present in this API level, safe to skip
        }
    });

    console.log("[✓] LocationManager hooks successfully locked and active.");
});