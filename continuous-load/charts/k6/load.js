import http from "k6/http";
import {check, sleep, group} from "k6";
import { Rate } from "k6/metrics";

const TARGET_SERVICES = __ENV.LOAD_TARGET_SERVICE
const REQ_PER_SECOND = __ENV.REQ_PER_SECOND || 3
const THRESHOLDS = __ENV.THRESHOLDS || "[\"p(90) < 400\", \"p(95) < 800\", \"p(99.9) < 2000\"]"
const SLEEP = __ENV.SLEEP || 1

export let options = {
    insecureSkipTLSVerify: true,
    userAgent: 'MyK6UserAgentString/1.0',
    summaryTrendStats: ["min", "avg", "med", "p(10)", "p(80)", "p(95)", "p(99)", "p(99.9)", "max", "count"],
    thresholds: {
      // 90% of requests must finish within 400ms, 95% within 800, and 99.9% within 2s.
      // e.g. ['p(90) < 400', 'p(95) < 800', 'p(99.9) < 2000']
      http_req_duration: JSON.parse(THRESHOLDS), 
    },
    scenarios: {
      open_model: {
        executor: 'constant-arrival-rate',
        rate: REQ_PER_SECOND,
        timeUnit: '1s',
        duration: '10m',
        preAllocatedVUs: 20,
      },
    },
};

// K6 "Rate" metric for counting Javascript errors during a test run.
var script_errors = Rate("script_errors");

// Wraps a K6 test function with error counting.
function wrapWithErrorCounting(fn) {
  return (data) => {
    try {
      fn(data);
      script_errors.add(0);
    } catch (e) {
      script_errors.add(1);
      throw e;
    }
  }
}

function loadTest(){
    group("static", function () {
        let responses = http.batch(JSON.parse(TARGET_SERVICES));
    });
    sleep(SLEEP);
}
export default wrapWithErrorCounting(loadTest);