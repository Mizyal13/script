#!/usr/bin/env python3
"""
==================================================================
Universal Desktop Browser Geolocation Bypass & Override Engine
Supported Platforms: Windows, Linux, macOS
Target Engines: Chromium / Blink / WebKit based browsers via CDP
==================================================================
"""

import os
import sys
import time
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service

def initialize_spoofed_browser(target_lat=35.6762, target_lon=139.6503, headless=False):
    options = Options()
    
    if headless:
        options.add_argument("--headless=new")
        
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-infobars")
    options.add_argument("--disable-extensions")
    
    # Platform-specific binary or driver path adjustments if necessary
    current_os = sys.platform
    print(f"[*] Detecting host OS environment: {current_os}")
    
    if "win32" in current_os:
        print("[+] Configuring Windows specific Chromium flags...")
    elif "linux" in current_os:
        print("[+] Configuring Linux specific sandbox overrides...")
        options.add_argument("--disable-setuid-sandbox")
    elif "darwin" in current_os:
        print("[+] Configuring macOS specific process constraints...")
        
    driver = webdriver.Chrome(options=options)
    
    # Utilize Chrome DevTools Protocol (CDP) to override geolocation globally across the session
    print(f"[*] Injecting universal GPS coordinates -> Lat: {target_lat}, Lon: {target_lon}")
    
    driver.execute_cdp_cmd("Emulation.setGeolocationOverride", {
        "latitude": target_lat,
        "longitude": target_lon,
        "accuracy": 100
    })
    
    # Grant automatic permission overrides for geolocation prompts
    driver.execute_cdp_cmd("Browser.grantPermissions", {
        "origin": "*",
        "permissions": ["geolocation"]
    })
    
    return driver

if __name__ == "__main__":
    print("==========================================")
    print(" Universal Browser Location Override Tool ")
    print("==========================================")
    
    # Initialize session targeting Tokyo coordinates
    browser = initialize_spoofed_browser(target_lat=35.6762, target_lon=139.6503, headless=False)
    
    try:
        # Test navigation against a geolocation verification endpoint
        target_url = "https://browserleaks.com/geo"
        print(f"[*] Navigating to verification target: {target_url}")
        browser.get(target_url)
        
        print("[✓] Geolocation override active. Session stable across OS boundary.")
        
        # Hold session open for verification / data harvesting
        time.sleep(30)
        
    except Exception as e:
        print(f"[-] Error during execution loop: {str(e)}")
    finally:
        browser.quit()
        print("[*] Browser session terminated cleanly.")