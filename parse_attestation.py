#!/usr/bin/env -S uv run
# /// script
# dependencies = ["cbor2", "cryptography"]
# ///
"""Parse and verify NitroTPM attestation documents."""

import base64
import sys
import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.exceptions import InvalidSignature


def parse_cose_sign1(b64_data: str) -> tuple[bytes, bytes, bytes, bytes]:
    """Parse COSE Sign1 structure, return (protected, unprotected, payload, signature)."""
    raw = base64.b64decode(b64_data)
    cose_sign1 = cbor2.loads(raw)

    # May be tagged (CBORTag 18) or untagged list
    if hasattr(cose_sign1, "value"):
        cose_array = cose_sign1.value
    else:
        cose_array = cose_sign1

    return cose_array[0], cose_array[1], cose_array[2], cose_array[3]


def verify_signature(protected: bytes, payload: bytes, signature: bytes, cert: x509.Certificate) -> bool:
    """Verify COSE Sign1 signature using the certificate's public key."""
    # Build Sig_structure for COSE Sign1: ["Signature1", protected, external_aad, payload]
    sig_structure = cbor2.dumps(["Signature1", protected, b"", payload])

    # COSE signatures are raw R||S format, convert to DER for cryptography library
    # ES384 uses P-384 curve with 48-byte R and S values
    r = int.from_bytes(signature[:48], "big")
    s = int.from_bytes(signature[48:], "big")
    der_sig = utils.encode_dss_signature(r, s)

    public_key = cert.public_key()
    try:
        # ES384 = ECDSA with SHA-384
        public_key.verify(der_sig, sig_structure, ec.ECDSA(hashes.SHA384()))
        return True
    except InvalidSignature:
        return False


def verify_cert_chain(cert: x509.Certificate, ca_bundle: list[bytes]) -> tuple[bool, str]:
    """Verify certificate chains to AWS Nitro root CA."""
    # Parse all certs in the chain
    chain = [x509.load_der_x509_certificate(ca_der) for ca_der in ca_bundle]

    # The root should be self-signed aws.nitro-enclaves
    root = chain[0]
    if "aws.nitro-enclaves" not in root.subject.rfc4514_string():
        return False, "Root CA is not aws.nitro-enclaves"

    # Verify chain: each cert should be signed by the next
    all_certs = chain + [cert]
    for i in range(len(all_certs) - 1):
        issuer = all_certs[i]
        subject = all_certs[i + 1]
        try:
            issuer.public_key().verify(
                subject.signature,
                subject.tbs_certificate_bytes,
                ec.ECDSA(hashes.SHA384())
            )
        except InvalidSignature:
            return False, f"Certificate {i+1} signature invalid"

    return True, "Certificate chain valid"


def parse_attestation(b64_data: str) -> tuple[dict, bool, str]:
    """Parse and verify attestation. Returns (doc, signature_valid, message)."""
    protected, _, payload, signature = parse_cose_sign1(b64_data)
    doc = cbor2.loads(payload)

    # Get certificate and CA bundle from attestation
    cert_der = doc.get("certificate")
    ca_bundle = doc.get("cabundle", [])

    if not cert_der:
        return doc, False, "No certificate in attestation"

    cert = x509.load_der_x509_certificate(cert_der)

    # Verify certificate chain
    chain_valid, chain_msg = verify_cert_chain(cert, ca_bundle)
    if not chain_valid:
        return doc, False, chain_msg

    # Verify COSE signature
    sig_valid = verify_signature(protected, payload, signature, cert)
    if not sig_valid:
        return doc, False, "COSE signature invalid"

    return doc, True, "Signature and certificate chain valid"


def main():
    if len(sys.argv) < 2:
        b64_file = "attest.b64"
    else:
        b64_file = sys.argv[1]

    with open(b64_file) as f:
        b64_data = f.read().strip()

    doc, sig_valid, msg = parse_attestation(b64_data)

    print(f"Signature: {'VALID' if sig_valid else 'INVALID'} - {msg}")
    print()
    print(f"Module ID: {doc.get('module_id', 'N/A')}")
    print(f"Digest: {doc.get('digest', 'N/A')}")
    print(f"Timestamp: {doc.get('timestamp', 'N/A')}")
    print()
    print("PCR Values (SHA384):")
    print("-" * 100)

    pcrs = doc.get("nitrotpm_pcrs", {})
    for i in range(24):
        pcr_value = pcrs.get(i, b"")
        if pcr_value:
            hex_value = pcr_value.hex().upper()
        else:
            hex_value = "(not present)"
        print(f"PCR {i:2d}: {hex_value}")

    sys.exit(0 if sig_valid else 1)


if __name__ == "__main__":
    main()
