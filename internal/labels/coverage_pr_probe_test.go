package labels

import "testing"

func TestCoveragePRProbe(test *testing.T) {
	actual := SelectorValue("coverage-pr-probe")
	if actual != "coverage-pr-probe" {
		test.Fatalf("SelectorValue returned %q, want coverage-pr-probe", actual)
	}
}