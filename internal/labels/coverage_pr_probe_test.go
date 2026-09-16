package labels

import "testing"

func TestCoveragePRProbe(test *testing.T) {
	test.Logf("exercised selector: %s", SelectorValue("coverage-pr-probe"))
	test.Fatal("intentional failure for disposable coverage-summary verification")
}