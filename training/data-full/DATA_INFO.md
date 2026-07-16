# Training data — AG News (full)

`train.csv` (120,000 rows) and `test.csv` (7,600 rows) are the complete
[AG News](https://huggingface.co/datasets/fancyzhx/ag_news) topic-classification
dataset (30,000/1,900 rows per class respectively).

- **Columns:** `text`, `label`
- **Labels:** `0` = World, `1` = Sports, `2` = Business, `3` = Sci/Tech
- **Size:** ~30 MB total (28 MB train, 1.8 MB test)
- **Use case:** Longer training runs for higher accuracy or GPU benchmarking.
  Pass `--dataset full` to the demo script, or `--data-dir /app/data-full`
  to `train.py` directly.
- **License:** AG News is provided by the academic community for
  research/non-commercial use — fine for this internal enablement demo, but
  don't redistribute it externally without checking
  [the original terms](http://groups.di.unipi.it/~gulli/AG_corpus_of_news_articles.html).

These CSVs are vendored (committed) so the training job never needs Hugging
Face Hub egress from inside the cluster.
