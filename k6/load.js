import http from "k6/http";
import {check, sleep, group} from "k6";
import { Rate } from "k6/metrics";

const TARGET_INGRESS = __ENV.LOAD_TARGET_INGRESS
const TARGET_SERVICE = __ENV.LOAD_TARGET_SERVICE
const RAMP_TIME = __ENV.RAMP_TIME || '1m'
const RUN_TIME = __ENV.RUN_TIME || '5m'
const USER_COUNT = __ENV.USER_COUNT || 10
const SLEEP = __ENV.SLEEP || 1

export let options = {
    insecureSkipTLSVerify: true,
    userAgent: 'MyK6UserAgentString/1.0',
    "stages": [
      { "target": USER_COUNT, "duration": RAMP_TIME }, // ramp-up
      { "target": USER_COUNT, "duration": RUN_TIME }, // steady
      { "target": 0, "duration": RAMP_TIME }  // ramp-down
    ],
    summaryTrendStats: ["min", "avg", "med", "p(95)", "p(99)", "p(99.9)", "p(99.99)", "max", "count"],
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
        let responses = http.batch([
          ['GET', TARGET_INGRESS, null, { tags: { 'type': 'ingress' } }],
          ['GET', TARGET_SERVICE, null, { tags: { 'type': 'service' } }],
        ]);
    });
    sleep(SLEEP);
}
export default wrapWithErrorCounting(loadTest);