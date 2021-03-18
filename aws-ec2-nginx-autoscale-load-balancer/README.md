A prototype web application infrastructure to evaluate the autoscaling abilities of AWS.
The auto scaling policy is target. if avg CPU is > 40%, then additional instances are spawned.
This is not an effective strategy when we have requests to the nginx server, as those requests
are mainly I/O. In these cases, we need to modify the autoscaling policy to include number of requests
or network I/O.
