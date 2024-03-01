#!/bin/bash
PEM_FILE=$1
PASSWORD=$2
KEYSTORE=$3

# Count the number of certificates in the PEM file
CERTS=$(grep 'END CERTIFICATE' "$PEM_FILE" | wc -l)

# For each certificate in the PEM file, extract it and import it into the JKS keystore
for N in $(seq 0 $(($CERTS - 1))); do
    ALIAS="${PEM_FILE%.*}-$N"
    cat "$PEM_FILE" | awk "n==$N { print }; /END CERTIFICATE/ { n++ }" | \
        keytool -noprompt -import -trustcacerts \
        -alias "$ALIAS" -keystore "$KEYSTORE" -storepass "$PASSWORD"
done
