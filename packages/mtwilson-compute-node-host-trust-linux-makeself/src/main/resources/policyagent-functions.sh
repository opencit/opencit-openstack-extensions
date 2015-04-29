

########## FUNCTIONS LIBRARY ##########
load_policyagent_conf() {
  POLICYAGENT_PROPERTIES_FILE=${POLICYAGENT_PROPERTIES_FILE:-"/opt/policyagent/configuration/policyagent.properties"}
  if [ -n "$DEFAULT_ENV_LOADED" ]; then return; fi

  # policyagent.properties file
  if [ -f "$POLICYAGENT_PROPERTIES_FILE" ]; then
    echo -n "Reading properties from file [$POLICYAGENT_PROPERTIES_FILE]....."
    export CONF_POLICYAGENT_ID=$(read_property_from_file "policyagent.id" "$POLICYAGENT_PROPERTIES_FILE")
    echo_success "Done"
  fi

  export DEFAULT_ENV_LOADED=true
  return 0
}

load_policyagent_defaults() {
  export DEFAULT_POLICYAGENT_ID=""

  export POLICYAGENT_ID=${POLICYAGENT_ID:-${CONF_POLICYAGENT_ID:-$DEFAULT_POLICYAGENT_ID}}
}

openssl_encrypted_file() {
  local filename="$1"
  encheader=`hd -n 8 $filename | head -n 1 | grep "Salted__"`
  if [ -n "$encheader" ]; then
    return 0
  fi
  return 1
}

pa_log() {
  #local datestr=`date '+%Y-%m-%d %H:%M:%S'`
  # use RFC 822 format
  local datestr=`date -R`
  echo "[$datestr] $$ $@" >> $logfile
}

# arguments:  <since-timestamp>
# the <since-timestamp> required argument is a timestamp where to start extracting data from the log
# lines in the log on or after the <since-timestamp> until the end are returned
# Usage example:  policyagent getlog 1382720512
# This would print all log statements on or after "Fri, 25 Oct 2013 10:01:52 -0700"
# To obtain a timestamp from a date in that format do this: date --utc --date "Fri, 25 Oct 2013 10:01:52 -0700" +%s
pa_getlog() {
  local since="$1"
  local trigger=false
  # default timestamp format for comparison is seconds since epoch (these days an 11 digit number)
  # if the caller supplied a 14-digit number they are including milliseconds so we add zeros to our format so we can compare
  local timestamp_format="%s"
  local since_length=`echo $since | wc -c`
  if [ $since_length -eq 14 ]; then timestamp_format="%s000"; fi
  while read line
  do
    if $trigger; then
      echo $line
    else
      # Given a logfile entry like "[Fri, 25 Oct 2013 10:01:59 -0700] 7088 Decrypted VM image",
      # extract the date using   awk -F '[][]' '{ print $2 }' which  outputs   Fri, 25 Oct 2013 10:01:59 -0700
      # and pass it to the date command using xargs -i ... {} ...  to create a command line like this:
      #  date --utc --date "Fri, 25 Oct 2013 10:01:52 -0700" +%s
      # which converts the date from that format into a  timestamp like 1383322675
      local linetime=`echo $line | awk -F '[][]' '{ print $2 }' | xargs -i date --utc --date "{}" +"$timestamp_format"`
      if [ -n "$linetime" ] && [ $linetime -ge $since ]; then
        trigger=true
        echo $line
      fi
    fi
  done < $logfile
}

pa_encrypt() {
  local infile="$1"
  local encfile="$infile.enc"
  if [ ! -f $infile ]; then
     echo "error: failed to encrypt $infile: file not found"
     return 1
  fi
  if openssl_encrypted_file $infile; then
    echo "error: failed to encrypt $infile: already encrypted";
    return 2;
  fi
  # XXX TODO need to change ciphers to aes-256-cbc and also add hmac for authentication!
  openssl enc -aes-128-ofb -in "$infile" -out "$encfile" -pass pass:password
  if openssl_encrypted_file $encfile; then
     mv $encfile $infile
     return 0
  fi
  echo "error: failed to encrypt $infile"
  return 3
}

pa_decrypt() {
  local infile="$1"
  local decfile="$infile.dec"
  
   PRIVATE_KEY=/opt/trustagent/configuration/bindingkey.blob
  
  if [ ! -f $infile ]; then
     echo "error: failed to decrypt $infile: file not found"
     return 1
  fi
  if ! openssl_encrypted_file $infile; then
     echo "error: failed to decrypt $infile: not encrypted";
     return 1
  fi
  if [ -n "$IMAGE_ID" ]; then
     pa_log "Found encrypted image: $IMAGE_ID"
  fi

  # XXX DEBUG for debugging only - copy the original image file to a tmp location for dev to look at it after
  #cp $infile /tmp/image.enc

  pa_request_dek $DEK_URL
  
  # XXX TODO (see note in pa_encrypt) need to change ciphers to aes-256-cbc and also add hmac for authentication!
  #openssl enc -d -aes-128-ofb -in "$infile" -out "$decfile" -pass pass:password
 
  #Uncomment the following line with new KMS integration
    #key_id=$INSTANCE_DIR/$IMAGE_ID".key"
    #tpm_unbindaeskey -k $PRIVATE_KEY -i $key_id  -o $key_id.dek
    #openssl enc -d -aes-128-ofb -in "$infile" -out "$decfile" -pass env:$key_id.dek
  #End of decrytion

  #delete these lines after uncommention above block
   export MH_DEK_DECODED=`openssl enc -base64 -d <<< $MH_DEK`
   pa_log "mh dek decoded::: $MH_DEK_DECODED";
   openssl enc -d -aes-128-ofb -in "$infile" -out "$decfile" -pass env:MH_DEK_DECODED
  #end of delete

  if ! openssl_encrypted_file $decfile; then
     if [ -n "$IMAGE_ID" ]; then
         pa_log "Decrypted image: $IMAGE_ID"
         # XXX DEBUG for debugging only - 
         #cp $decfile /tmp/image.dec
     fi
     mv $decfile $infile
     return 0
  fi
  echo "error: failed to decrypt $infile"
  return 2
}

parse_args() {
  if ! options=$(getopt -n policyagent -l project-id:,instance-name:,base-image:,image-id:,target:,checksum:,dek-url:,manifest_uuid:,instance_id:,mtwilson_trust_policy: -- "$@"); then exit 1; fi
  eval set -- "$options"
  while [ $# -gt 0 ]
  do
    case $1 in
      --project-id) PROJECT_ID="$2"; shift;;
      --instance-name) INSTANCE_NAME="$2"; shift;;
      --base-image) BASE_IMAGE="$2"; shift;;
      --image-id) IMAGE_ID="$2"; shift;;
      --target) TARGET="$2"; shift;;
      --checksum) CHECKSUM="$2"; shift;;
      --dek-url) DEK_URL="$2"; shift;;
      --manifest_uuid) MANIFEST_UUID="$2";shift;;
      --instance_id) INSTANCE_ID="$2";shift;;
      --mtwilson_trust_policy) MTW_TRUST_POLICY="$2";shift;;
    esac
    shift
  done
}

pa_launch() {
  pa_log "pa_launch: $@"
  pa_log "Project Id: $PROJECT_ID"
  pa_log "Instance Name: $INSTANCE_NAME"
  pa_log "Base Image: $BASE_IMAGE"
  pa_log "Image Id: $IMAGE_ID"
  pa_log "Target: $TARGET"
  pa_log "Checksum: $CHECKSUM"
  pa_log "DEK URL: $DEK_URL"
  pa_log "MANIFEST UUID: $MANIFEST_UUID"
  pa_log "INSTANCE ID: $INSTANCE_ID"
  pa_log "MTW_TRUST_POLICY: $MTW_TRUST_POLICY"
  INSTANCE_DIR=$INSTANCE_DIR/$INSTANCE_ID
  pa_log "INSTANCE_DIR: $INSTANCE_DIR"

  if [ -n "$TARGET" ]; then
     if [ -f $TARGET ]; then
         pa_log "Found base image: $TARGET"
         pa_log "***BASE IMAGE FOUND"
         #Untar the image and Trust policy
         temp_dir=$TARGET"_temp"
         trustPolicyTarget="${TARGET}.xml"
         #if [ ! -d "$policyagent_dir"/"$INSTANCE_ID" ]; then
              pa_log "Created instance dir"
           mkdir $temp_dir
        #fi
 
        
        ls -ltar $TARGET >> $logfile
        if [ "$MTW_TRUST_POLICY" == "glance_image_tar" ]; then
            pa_log " Image is been downloaded from the glance"
            tar -xvf $TARGET -C $temp_dir
            ls -l $temp_dir >> $logfile
            mv $temp_dir/*.xml $trustPolicyTarget
            pa_log "*******************************************"
            image_path=`find $temp_dir -name '*.[img|vhd|raw]*'`
            pa_log "Image Path is $image_path"
            pa_log "*******************************************"
            if [ -n $image_path ]; then
               cp $image_path $TARGET
            else  
                pa_log "Failed to untar and copy the image successfully"
                exit 1
                fi
                #ls -ltar $TARGET >> $logfile
                #Untar
       else
            # There will be other sources like swift to add later
            pa_log "Image is not downloaded from the glance"
       fi
        
        #Start TP Check the Encryption Tag, extract DEK and Checksum
        if [ -n "$trustPolicyTarget" ]; then
           is_encrypted=`grep -r "<Encryption" $trustPolicyTarget`
           if [ ! -z "$is_encrypted" ]; then
               pa_log "Received an encrypted image"
               CHECKSUM=`cat $trustPolicyTarget | xmlstarlet fo --noindent | sed -e 's/ xmlns.*=".*"//g' | xmlstarlet sel -t -v "/TrustPolicy/Encryption/Checksum"`
               DEK_URL=`cat $trustPolicyTarget | xmlstarlet fo --noindent | sed -e 's/ xmlns.*=".*"//g' | xmlstarlet sel -t -v "/TrustPolicy/Encryption/Key"`
               pa_log "Checksum: $CHECKSUM"
               pa_log "DEK URL: $DEK_URL"
           else
               pa_log " The image is not encrypted: no checksum and dek_url received"
           fi
           #End TP
           cp $trustPolicyTarget $INSTANCE_DIR/"manifest.xml"
           pa_log "*****TrustPolicy Location: $trustPolicyTarget"
           #Call the Verifier Java snippet
           pa_log "Java Func call print here: /usr/bin/java -classpath  $verifierJavaLoc $javaClassName $trustPolicyTarget"
           /usr/bin/java -classpath  "$verifierJavaLoc" "$javaClassName" "$trustPolicyTarget"
           verifier_exit_status=$(echo $?)
           pa_log "signature verfier ExitCode: $verifier_exit_status"
           if [ $verifier_exit_status -eq 0 ]; then
               pa_log " Signature verification was successful"
               pa_log "policy agent will proceed to decrypt the image"
           else
               pa_log "Signature verification was unsuccessful. The launch process wil be aborted"
               exit 1
           fi
      fi
 
     #if the verification was successful, perform the xml parsing here
     cat $trustPolicyTarget | xmlstarlet fo --noindent | sed -e 's/ xmlns.*=".*"//g' | xmlstarlet sel -t -c "/TrustPolicy/Whitelist" | xmlstarlet ed -u '/Whitelist/*' -v '' | xmlstarlet ed -r "Whitelist" -v "Manifest" |xmlstarlet ed -r "/Manifest/@DigestAlg" -v 'xmlns="mtwilson:trustdirector:manifest:1.1" DigestAlg'> $INSTANCE_DIR/manifestlist.xml
     #cat $trustPolicyTarget >> $logfile
     #cat $INSTANCE_DIR/manifestlist.xml >> $logfile
     ls -l $INSTANCE_DIR >> $logfile

      #md5sum /var/lib/nova/instances/_base/$BASE_IMAGE >> $logfile
      # We rely on pa_decrypt to detect if the file is encrypted or not
      # (it could already be decrypted if this isn't the first launch)
      #pa_decrypt /var/lib/nova/instances/_base/$BASE_IMAGE >> $logfile
      if [ ! -z $CHECKSUM ]; then
          pa_decrypt $TARGET >> $logfile
      # Either way we check that now the image checksum should match
      # what was passed in via --checksum
      #local current_md5=$(md5 /var/lib/nova/instances/_base/$BASE_IMAGE)
      local current_md5=$(md5 $TARGET)
      pa_log "Checksum after decryption: $current_md5"
      if [ "$current_md5" != "$CHECKSUM" ]; then
          pa_log "Error: checksum is $current_md5 but expected $CHECKSUM"
          exit 1
      fi
      else
         pa_log "The image is not encrypted"
    fi
    else
        pa_log "File not found: $TARGET"
        exit 1
    fi
   else
       pa_log "Missing parameter --target"
       exit 1
  fi
  #if [ -d /var/lib/nova/instances/$INSTANCE_NAME ]; then
  #  INSTANCE_DIR=/var/lib/nova/instances/$INSTANCE_NAME 
  #  pa_log "Instance Path: $INSTANCE_DIR"
  #fi
  #if [ -f /var/lib/nova/instances/_base/$PROJECT_ID ]; then
  #  PROJECT_FILE=/var/lib/nova/instances/_base/$PROJECT_ID
  #  pa_log "Base Image:  $PROJECT_FILE"
  #fi
  #if [ -n "$PROJECT_FILE" ]; then
  #  if [ -f "$PROJECT_FILE" ]; then
  #    pa_log "pa_launch: Decrypting $PROJECT_FILE"
  #    pa_decrypt $PROJECT_FILE >> $logfile
  #  else
  #    pa_log "pa_launch: Cannot decrypt file: file not found"
  #  fi
  #else
  #  pa_log "pa_launch: Cannot decrypt file: no base image"
  #fi
}

pa_terminate() {
  pa_log "pa_terminate: $@"
}

pa_suspend() {
  pa_log "pa_suspend: $@"
}

pa_suspend_resume() {
  pa_log "pa_suspend_resume: $@"
}

pa_pause() {
  pa_log "pa_pause: $@"
}

pa_pause_resume() {
  pa_log "pa_pause_resume: $@"
}

pa_fix_aik() {
  local aikdir=/etc/intel/cloudsecurity/cert

  # first prepare the aik for posting. trust agent keeps the aik at /etc/intel/cloudsecurity/cert/aikcert.cer in PEM format.
  if [ ! -f $aikdir/aikcert.crt ]; then
    if [ ! -f $aikdir/aikcert.pem ]; then
      # trust agent aikcert.cer is in broken PEM format... it needs newlines every 76 characters to be correct
      cat $aikdir/aikcert.cer | sed 's/.\{76\}/&\n/g' > $aikdir/aikcert.pem
    fi
    if [ -f $aikdir/aikcert.pem ]; then
      openssl x509 -in $aikdir/aikcert.pem -inform pem -out $aikdir/aikcert.crt -outform der
    fi
  fi

  if [ ! -f $aikdir/aikpubkey.pem ]; then
    if [ -f $aikdir/aikcert.crt ]; then
      openssl x509 -in $aikdir/aikcert.crt -inform der -pubkey -noout > $aikdir/aikpubkey.pem
      openssl rsa -in $aikdir/aikpubkey.pem -inform pem -pubin -out $aikdir/aikpubkey -outform der -pubout
    fi
  fi
}

# example:
# pa_request_dek https://10.254.57.240:8443/v1/data-encryption-key/request/testkey2
pa_request_dek() {
  local url="$1"
  local aikdir
  local dekdir
  if [ -x /opt/xensource/tpm/xentpm ]; then
    local aikblobfile=/opt/xensource/tpm/aiktpmblob
    if [ -f $aikblobfile ]; then
      /opt/xensource/tpm/xentpm --get_aik_pem $aikblobfile > /tmp/aikpubkey.pem
    else
      /opt/xensource/tpm/xentpm --get_aik_pem > /tmp/aikpubkey.pem
    fi
    aikdir=/tmp
    dekdir=/tmp
  else
    pa_fix_aik
    aikdir=/opt/trustagent/configuration
    dekdir=/var/lib/nova
  fi
  if [ ! -f $aikdir/aik.pem ]; then
    pa_log "Error: Missing AIK Public Key";
    echo "Missing AIK Public Key";
    exit 1
  fi

  #wget --no-check-certificate --header "Content-Type: application/octet-stream" --post-file=$aikdir/aikcert.crt "$url"
  #curl --verbose --insecure -X POST -H "Content-Type: application/octet-stream" --data-binary @$aikdir/aikcert.crt "$url"

  pa_log "Requesting DEK from: $url"
  curl --insecure --silent -X POST -H "Content-Type: text/plain" --data-binary @$aikdir/aik.pem "$url" > $dekdir/mh.dek.base64
  
  #Uncomment the following line for new KMS integration and comment the above line
  #Uncomment the below line to integrate the KMS proxy
  #curl --proxy http://$kms_proxy_ipaddress:9080 --verbose -X POST -H "Content-Type: application/x-pem-file" -H "Accept: application/octet-stream" --data-binary @$aikdir/aik.pem  "$url" > $INSTANCE_DIR/$IMAGE_ID".key"

  #export MH_DEK_RAW=`cat $dekdir/mh.dek`
  if [ ! -z "$dekdir/mh.dek.base64" ]; then
      export MH_DEK_BASE64=`cat $dekdir/mh.dek.base64`
    
      # if client uses the raw key as input to openssl:
      #base64 -d < $dekdir/mh.dek.base64 > $dekdir/mh.dek
      #export MH_DEK=`cat $dekdir/mh.dek`
      # if client uses the base64 encoded key as input to openssl:
      export MH_DEK="$MH_DEK_BASE64"
      pa_log "Received DEK from: $url"
      #pa_log "Received DEK: $MH_DEK"
      # XXX TODO need to have an output file option where caller can specify to save the DEK, and an environment option to place it in an env var and then we would also delete these temp files
      #rm $dekdir/mh.dek
      #rm $dekdir/mh.dek.base64
      # XXX DEBUG INSECURE for debugging only:  remove this to protect the key
      pa_log "MH_DEK_BASE64: $MH_DEK_BASE64"
  else
      pa_log " Failed to retrieve the decryption key from the key server"
      exit 1
  fi

}
