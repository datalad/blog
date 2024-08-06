---
title: 'Collecting runtime statistics and outputs with `con-duct` and `datalad-run`'
date: 2024-07-30
author:
- Austin Macdonald
tags:
- DataLad
- datalad-run
- duct
- con-duct
- statistics
- resources
cover:
  image: airduct.webp
  relative: true
description: >
  Collect even more useful information with `datalad-run` by pairing with `con-duct`
showToc: true
---

One of the challenges that I've experienced when attempting to replicate the execution of data analysis is quite simply that information regarding the required resources is sparse.
For example, when submitting a SLURM job, how does one know the wallclock time to request, much less memory and CPU resources?

To solve this problem we at the [Center for Open
Neuroscience][https://centerforopenneuroscience.org/] have created a new tool, `con-duct` aka
`duct` to easily collect this information.
When combined with `datalad-run`, `duct` collects crucial runtime information for future replication
and reuse. 

## Demo

To show off `duct`, lets use the DataLad-101 and LongNow podcast examples from the [DataLad handbook](https://handbook.datalad.org/en/latest/basics/101-105-install.html)

Clone the repository, and populate the longnow podcasts.
```
git clone git@github.com:datalad-handbook/DataLad-101.git
cd DataLad-101
git checkout -b duct-demo
datalad clone --dataset .  https://github.com/datalad-datasets/longnow-podcasts.git recordings/longnow
```

Now let's install `con-duct`:

```
pip install con-duct
```

We now have our podcasts, and just like the [datalad run section](https://handbook.datalad.org/en/latest/basics/101-108-run.html) of the handbook we can generate a list of titles, except this time we will prepend the command with a `duct` wrapper to collect runtime statistics.

Note: we must use `--quiet` since we are using `>` to capture the output of the script, we don't want to pollute it with `duct` output.

```
datalad run -m "Use datalad run with duct to create a list of podcast titles, and capture runtime information" \
  "duct --sample-interval 0.01 --report-interval 0.1 --quiet bash code/list_titles.sh > recordings/recordings.tsv"

run(ok): /home/austin/devel/DataLad-101 (dataset) [duct --sample-interval 0.01 --report-int...]
add(ok): .duct/logs/2024.07.30T09.02.01-110957_info.json (file)
add(ok): .duct/logs/2024.07.30T09.02.01-110957_stderr (file)
add(ok): .duct/logs/2024.07.30T09.02.01-110957_stdout (file)
add(ok): .duct/logs/2024.07.30T09.02.01-110957_usage.json (file)
add(ok): recordings/recordings.tsv (file)
save(ok): . (dataset)
```

In addition to the `recordings.tsv` we also have a set of files describing the execution.

```
ls .duct/logs
2024.07.30T09.02.01-110957_info.json
2024.07.30T09.02.01-110957_stderr
2024.07.30T09.02.01-110957_stdout
2024.07.30T09.02.01-110957_usage.json
```

We've captured the output of the command (which in this example was captured anyway with `>`):

```
cat .duct/logs/*_stdout
2017-06-09	How Digital Memory Is Shaping Our Future  Abby Smith Rumsey
2017-06-09	Pace Layers Thinking  Stewart Brand  Paul Saffo
2017-06-09	Proof  The Science of Booze  Adam Rogers
... <snip>
```

If there were errors, we've captured them as well, but in this case we just have an empty file.

```
cat .duct/logs/*_stderr # should be empty
```

We also have a summary of the environment and statistics about the entire run. 
This information may be particularly helpful during replication-- the replicator will now have crucial information to estimate the resources they will need!

```
cat .duct/logs/*_info.json | jq
{
  "command": "bash code/list_titles.sh",
  "system": {
    "uid": "austin",
    "memory_total": 33336778752,
    "cpu_total": 20
  },
  "env": {},
  "gpu": null,
  "duct_version": "0.1.0",
  "execution_summary": {
    "exit_code": 0,
    "command": "bash code/list_titles.sh",
    "logs_prefix": ".duct/logs/2024.07.30T09.02.01-110957_",
    "wall_clock_time": "0.611 sec",
    "peak_rss": "3680 KiB",
    "average_rss": "3543.704 KiB",
    "peak_vsz": "223344 KiB",
    "average_vsz": "215072.000 KiB",
    "peak_pmem": "0.0%",
    "average_pmem": "0.000%",
    "peak_pcpu": "0.0%",
    "average_pcpu": "0.000%",
    "num_samples": 27,
    "num_reports": 7
  }
}
```

For more fine-grained information (especially useful to generate graphs), we also have a collection of reports to indicate usage over time.

Each report can be an aggregation of 1 or more samples, it shows the resource utilization of each process, and the total of all related processes.
```
cat .duct/logs/*_usage.json | jq
{
  "timestamp": "2024-07-30T09:02:01.524299-05:00",
  "num_samples": 1,
  "processes": {
    "110960": {
      "pcpu": 0.0,
      "pmem": 0.0,
      "rss": 3680,
      "vsz": 223344,
      "timestamp": "2024-07-30T09:02:01.524299-05:00"
    }
  },
  "totals": {
    "pmem": 0.0,
    "pcpu": 0.0,
    "rss_kb": 3680,
    "vsz_kb": 223344
  },
  "averages": {
    "rss": 3680,
    "vsz": 223344,
    "pmem": 0.0,
    "pcpu": 0.0,
    "num_samples": 1
  }
}
... <snip>
```
