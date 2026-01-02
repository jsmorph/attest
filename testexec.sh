#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

# Create demo.sh via heredoc
cat > demo.sh << 'EOF'
#!/bin/sh
echo "hello from script"
EOF

# Build AMI with appexec.sh
echo "Building AMI with appexec.sh..."
./build.sh appexec.sh 2>&1 | tee build.log
AMI_ID=$(grep "AMI ID:" build.log | awk '{print $3}')

if [[ -z "$AMI_ID" ]]; then
    echo "TEST FAILED: Could not extract AMI ID from build output"
    exit 1
fi

echo "Built AMI: $AMI_ID"

# Run with exec.sh
echo "Running exec.sh with demo.sh..."
./exec.sh "$AMI_ID" demo.sh | tee test.txt

# Check for expected output
if grep -q "hello from script" test.txt; then
    echo "TEST PASSED"
else
    echo "TEST FAILED: 'hello from script' not found in output"
    exit 1
fi
