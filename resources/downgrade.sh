#!/bin/bash

FRBaseband() {
    local BasebandSHA1L
    
    if [[ $DeviceProc == 7 ]]; then
        mkdir -p saved/baseband 2>/dev/null
        cp -f $IPSWRestore/Firmware/$Baseband saved/baseband
    fi

    if [[ ! -e saved/baseband/$Baseband ]]; then
        Log "Downloading baseband..."
        $partialzip $BasebandURL Firmware/$Baseband $Baseband
        $partialzip $BasebandURL BuildManifest.plist BuildManifest.plist
        mkdir -p saved/$ProductType saved/baseband 2>/dev/null
        mv $Baseband saved/baseband
        mv BuildManifest.plist saved/$ProductType
        BuildManifest="saved/$ProductType/BuildManifest.plist"
    elif [[ $DeviceProc != 7 ]]; then
        BuildManifest="saved/$ProductType/BuildManifest.plist"
    fi

    BasebandSHA1L=$(shasum saved/baseband/$Baseband | awk '{print $1}')
    if [[ ! -e $(ls saved/baseband/$Baseband) || $BasebandSHA1L != $BasebandSHA1 ]]; then
        rm -f saved/baseband/$Baseband saved/$ProductType/BuildManifest.plist
        if [[ $DeviceProc == 7 ]]; then
            Error "Downloading/verifying baseband failed. Please run the script again"
        else
            Log "Downloading/verifying baseband failed, will proceed with --latest-baseband flag"
            return 1
        fi
    fi
}

Downgrade() {
    local ExtraArgs=("--use-pwndfu")
    local IPSWExtract
    Verify=1
    
    Log "Select your options when asked. If unsure, go for the defaults (press Enter/Return)."
    echo

    if [[ $OSVer == "Other" ]]; then
        Input "Select your IPSW file in the file selection window."
        IPSW="$($zenity --file-selection --file-filter='IPSW | *.ipsw' --title="Select IPSW file")"
        [[ ! -s "$IPSW" ]] && Error "No IPSW selected, or IPSW file not found."
        IPSW="${IPSW%?????}"
        Log "Selected IPSW file: $IPSW.ipsw"
        Input "Select your SHSH file in the file selection window."
        SHSH="$($zenity --file-selection --file-filter='SHSH | *.shsh *.shsh2' --title="Select SHSH file")"
        [[ ! -s "$SHSH" ]] && Error "No SHSH selected, or SHSH file not found."
        Log "Selected SHSH file: $SHSH"

        unzip -o -j "$IPSW.ipsw" Restore.plist -d tmp
        BuildVer=$(cat tmp/Restore.plist | grep -i ProductBuildVersion -A 1 | grep -oPm1 "(?<=<string>)[^<]+")
        Log "Getting firmware keys for $ProductType-$BuildVer"
        mkdir resources/firmware/$ProductType/$BuildVer 2>/dev/null
        curl -L https://github.com/LukeZGD/iOS-OTA-Downgrader-Keys/raw/master/$ProductType/$BuildVer/index.html -o tmp/index.html
        mv tmp/index.html resources/firmware/$ProductType/$BuildVer

    elif [[ $DeviceProc != 7 ]]; then
        Input "Jailbreak Option"
        Echo "* When this option is enabled, your device will be jailbroken on restore."
        if [[ $ProductType == "iPad2,5" || $ProductType == "iPad2,6" || $ProductType == "iPad2,7" ]]; then
            Echo "* Based on some reported issues, Jailbreak Option might be broken for iPad mini 1 devices."
            Echo "* I recommend to disable the option for these devices and sideload EtasonJB, HomeDepot, or daibutsu manually."
        fi
        Echo "* This option is enabled by default (Y)."
        read -p "$(Input 'Enable this option? (Y/n):')" Jailbreak
        
        if [[ $Jailbreak != 'N' && $Jailbreak != 'n' ]]; then
            JailbreakSet
            Log "Jailbreak option enabled."
        else
            Log "Jailbreak option disabled by user."
        fi
        echo
    fi
    
    if [[ $OSVer != "Other" ]]; then
        [[ -z $IPSWCustom ]] && IPSWCustom="${IPSWType}_${OSVer}_${BuildVer}_Custom"

        MemoryOption
        SaveOTABlobs
        IPSWFind

        if [[ $Verify == 1 ]]; then
            IPSWVerify
        elif [[ -e "$IPSWCustom.ipsw" ]]; then
            Log "Found existing Custom IPSW. Skipping IPSW verification."
            Log "Setting restore IPSW to: $IPSWCustom.ipsw"
            IPSWRestore=$IPSWCustom
        fi
    
        if [[ $DeviceState == "Normal" && $iBSSBuildVer == $BuildVer && -e "$IPSW.ipsw" ]]; then
            Log "Extracting iBSS from IPSW..."
            mkdir -p saved/$ProductType 2>/dev/null
            unzip -o -j $IPSW.ipsw Firmware/dfu/$iBSS.dfu -d saved/$ProductType
        fi
    else
        IPSWCustom=0
    fi

    [[ $DeviceState == "Normal" ]] && kDFU

    if [[ $Jailbreak == 1 ]]; then
        IPSW32
        IPSWExtract="$IPSWCustom"
    else
        IPSWExtract="$IPSW"
    fi

    Log "Extracting IPSW: $IPSWExtract.ipsw"
    unzip -oq "$IPSWExtract.ipsw" -d "$IPSWExtract"/

    if [[ ! $IPSWRestore ]]; then
        Log "Setting restore IPSW to: $IPSW.ipsw"
        IPSWRestore="$IPSW"
    fi

    Log "Proceeding to futurerestore..."
    [[ $platform == "linux" ]] && Echo "* Enter your user password when prompted"
    cd resources
    $SimpleHTTPServer &
    ServerPID=$!
    cd ..

    if [[ $DeviceProc == 7 ]]; then
        # Send dummy file for device detection
        $irecovery -f README.md
        sleep 2
        ExtraArgs+=("-s" "$IPSWRestore/Firmware/all_flash/$SEP" "-m" "$BuildManifest")
    else
        ExtraArgs+=("--no-ibss")
    fi

    if [[ $Baseband == 0 ]]; then
        Log "Device $ProductType has no baseband"
        ExtraArgs+=("--no-baseband")
    else
        FRBaseband
        if [[ $? == 1 ]]; then
            ExtraArgs+=("--latest-baseband")
        else
            ExtraArgs+=("-b" "saved/baseband/$Baseband" "-p" "$BuildManifest")
        fi
    fi

    Log "Running futurerestore with command: $futurerestore -t \"$SHSH\" ${ExtraArgs[*]} \"$IPSWRestore.ipsw\""
    $futurerestore -t "$SHSH" "${ExtraArgs[@]}" "$IPSWRestore.ipsw"
    if [[ $? != 0 ]]; then
        Log "An error seems to have occurred in futurerestore."
        Echo "* Please read the \"Troubleshooting\" wiki page in GitHub before opening any issue!"
        Echo "* Your problem may have already been addressed within the wiki page."
        Echo "* If opening an issue in GitHub, please provide a FULL log. Otherwise, your issue may be dismissed."
    else
        echo
        Log "Restoring done!"
    fi
    Log "Downgrade script done!"
}
