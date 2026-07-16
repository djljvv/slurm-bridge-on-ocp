# Training data — AG News (subset)

`train.csv` (8,000 rows) and `test.csv` (2,000 rows) are a fixed, class-balanced,
seeded subset of the [AG News](https://huggingface.co/datasets/fancyzhx/ag_news)
topic-classification dataset (2,000/500 rows per class respectively).

- **Columns:** `text`, `label`
- **Labels:** `0` = World, `1` = Sports, `2` = Business, `3` = Sci/Tech
- **Why a subset:** the full dataset (120k train / 7.6k test, ~20MB) is small
  enough to vendor in full, but fine-tuning on all of it would take too long
  for a demo on CPU. This subset is sized to fine-tune in a reasonable amount
  of time while still being enough data to move accuracy from chance-level
  (~25%, since there are 4 classes) to ~80%+.
- **License:** AG News is provided by the academic community for
  research/non-commercial use — fine for this internal enablement demo, but
  don't redistribute it externally without checking
  [the original terms](http://groups.di.unipi.it/~gulli/AG_corpus_of_news_articles.html).

These CSVs are vendored (committed) so the training job never needs Hugging
Face Hub egress from inside the cluster.
