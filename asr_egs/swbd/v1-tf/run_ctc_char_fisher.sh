#!/bin/bash
#

#PBS -M ramon.sanabria.teixidor@gmail.com
#PBS -q gpu
#PBS -j oe
#PBS -o log
#PBS -d .
#PBS -N eesen_tf_swbd_pipeline_char
#PBS -V
#PBS -l walltime=48:00:00
#PBS -l nodes=1:ppn=1


#SBATCH --job-name=fisher_feats
#SBATCH --output=log/fisher_extract_1
#SBATCH --ntasks=16
#SBATCH --time=48:00:00


. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.
. ./path.sh

stage=1

# CMU Rocks
swbd=/data/ASR4/babel/ymiao/CTS/LDC97S62
fisher_dirs="/data/ASR5/babel/ymiao/Install/LDC/LDC2004T19/fe_03_p1_tran/ /data/ASR5/babel/ymiao/Install/LDC/LDC2005T19/fe_03_p2_tran/"
eval2000_dirs="/data/ASR4/babel/ymiao/CTS/LDC2002S09/hub5e_00 /data/ASR4/babel/ymiao/CTS/LDC2002T43"

. parse_options.sh


#acoustic model parameters
am_nlayer=4
am_ncell_dim=320
am_model=deepbilstm
am_window=3
am_norm=false

dir_am=exp/train_char_l${am_nlayer}_c${am_ncell_dim}_m${am_model}_w${am_window}_n${am_norm}


#language model parameters
fisher_dir_a="/data/ASR5/babel/ymiao/Install/LDC/LDC2004T19/fe_03_p1_tran/"
fisher_dir_b="/data/ASR5/babel/ymiao/Install/LDC/LDC2005T19/fe_03_p2_tran/"

lm_embed_size=64
lm_batch_size=32
lm_nlayer=1
lm_ncell_dim=1024
lm_drop_out=0.5
lm_optimizer="adam"

dir_lm=exp/train_lm_char_l${lm_nlayer}_c${lm_ncell_dim}_e${lm_embed_size}_d${lm_drop_out}_o${lm_optimizer}/

fisher_text_dir="./data/fisher/"


#fisher_dirs="/pylon2/ir3l68p/metze/LDC2004T19 /pylon2/ir3l68p/metze/LDC2005T19 /pylon2/ir3l68p/metze/LDC2004S13 /pylon2/ir3l68p/metze/LDC2005S13"
fisher_dirs="/data/MM1/corpora/LDC2004T19 /data/MM1/corpora/LDC2005T19 /data/MM1/corpora/LDC2004S13 /data/MM1/corpora/LDC2005S13"


if [ $stage -le 1 ]; then
  echo =====================================================================
  echo "                       Data Preparation                            "
  echo =====================================================================

  #data prep for fisher (./data/train_fisher)
  tmpfisher=`mktemp -d`
  local/fisher_data_prep.sh --dir ./data/train_fisher/ --local-dir $tmpfisher $fisher_dirs
  rm -r $tmpfisher
  rm ./data/train_fisher/spk2gender

  #data prep for normal swbd (./data/train/)
  local/swbd1_data_prep.sh $swbd  || exit 1;

  # Represent word spellings using a dictionary-like format
  local/swbd1_prepare_char_dict.sh || exit 1;

  # Data preparation for the eval2000 set (./data/eval2000/)
  local/eval2000_data_prep.sh $eval2000_dirs
fi


if [ $stage -le 2 ]; then
  echo =====================================================================
  echo "                    FBank Feature Generation                       "
  echo =====================================================================

  #extract fisher
  fbankdir=fbank

  # FISHER: Generate the fbank features + pitch; by default 40-dimensional fbanks on each frame
  steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 16 data/train_fisher/ exp/make_fbank/train_fisher/ $fbankdir || exit 1;
  steps/compute_cmvn_stats.sh data/train_fisher exp/make_fbank/train_fisher $fbankdir || exit 1;
  utils/fix_data_dir.sh data/train_fisher || exit;


  # SWBD: Generate the fbank features + pitch; by default 40-dimensional fbanks on each frame
  steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 data/train exp/make_fbank/train $fbankdir || exit 1;
  steps/compute_cmvn_stats.sh data/train exp/make_fbank/train $fbankdir || exit 1;
  utils/fix_data_dir.sh data/train || exit;

  # EVAL2000: Generate the fbank features + pitch; by default 40-dimensional fbanks on each frame
  steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 10 data/eval2000 exp/make_fbank/eval2000 $fbankdir || exit 1;
  steps/compute_cmvn_stats.sh data/eval2000 exp/make_fbank/eval2000 $fbankdir || exit 1;
  utils/fix_data_dir.sh data/eval2000 || exit;

  # Use the first 4k sentences as dev set, around 5 hours
  utils/subset_data_dir.sh --first data/train 4000 data/train_dev
  n=$[`cat data/train/segments | wc -l` - 4000]
  utils/subset_data_dir.sh --last data/train $n data/train_nodev

  # FISHER: limiting any utterance to be repeated 300 times as max
  local/remove_dup_utts.sh 300 data/train_fisher data/train_fisher_nodup

  # SWBD: limiting any utterance to be repeated 300 times as max
  local/remove_dup_utts.sh 300 data/train_nodev data/train_nodup

  # merge two datasets into one
  mkdir -p data/train_all
  for f in spk2utt utt2spk wav.scp text segments reco2file_and_channel feats.scp cmvn.scp; do
        cat data/train_fisher_nodup/$f data/train_nodup/$f > data/train_all/$f
  done

   #Finally, we can use the following sets:
   #./data/train_all: training set
   #./data/train_dev: development set
   #./data/eval2000: test set

fi

if [ $stage -le 3 ]; then
  echo =====================================================================
  echo "                Training AM with the Full Set                      "
  echo =====================================================================

  mkdir -p $dir_am

  echo generating train labels...

  python ./local/swbd1_prepare_char_dict_tf.py --text_file ./data/train_all/text --output_units ./data/local/dict_char/units.txt --output_labels $dir_am/labels.tr --lower_case --ignore_noises || exit 1

  echo generating cv labels...

  python ./local/swbd1_prepare_char_dict_tf.py --text_file ./data/train_dev/text --input_units ./data/local/dict_char/units.txt --output_labels $dir_am/labels.cv || exit 1

  # Train the network with CTC. Refer to the script for details about the arguments
  steps/train_ctc_tf.sh --nlayer $am_nlayer --nhidden $am_ncell_dim  --batch_size 16 --learn_rate 0.005 --half_after 6 --model $am_model --window $am_window --norm $am_norm data/train_all data/train_dev $dir_am || exit 1;

fi

if [ $stage -le 4 ]; then

  echo =====================================================================
  echo "                   Decoding eval200 using AM                      "
  echo =====================================================================

  epoch=epoch09.ckpt
  filename=$(basename "$epoch")
  name_exp="${filename%.*}"
  #name_exp=./exp/train_char_l4_c320_mdeepbilstm_w3_nfalse_thomas/

  data=./data/eval2000/
  weights=$dir_lm/model/$epoch
  config=$dir_lm/model/config.pkl
  results=$dir_lm/results/$name_exp

  ./steps/decode_ctc_am_tf.sh --config $config --data $data --weights $weights --results $results

  exit
fi

if [ $stage -le 5 ]; then
  echo =====================================================================
  echo "             Char RNN LM Training with the Full Set                "
  echo =====================================================================

  mkdir -p $dir_lm
  mkdir -p ./data/local/dict_char_lm/

  echo ""
  echo creating labels files from train...
  echo ""

  python ./local/swbd1_prepare_char_dict_tf.py --text_file ./data/train_nodup/text --input_units ./data/local/dict_char/units.txt --output_units ./data/local/dict_char_lm/units.txt --output_labels $dir_lm/labels.tr --lm

  echo ""
  echo creating word list from train...
  echo ""

  python ./local/swbd1_prepare_word_list_tf.py --text_file ./data/train_nodup/text --output_word_list $dir_lm/words.tr --ignore_noises


  echo ""
  echo creating labels files from cv...
  echo ""

  python ./local/swbd1_prepare_char_dict_tf.py --text_file ./data/train_dev/text --input_units ./data/local/dict_char_lm/units.txt --output_labels $dir_lm/labels.cv --lm

  echo ""
  echo creating word list from cv...
  echo ""

  python ./local/swbd1_prepare_word_list_tf.py --text_file ./data/train_dev/text --output_word_list $dir_lm/words.cv --ignore_noises

  echo ""
  echo generating fisher_data...
  echo ""

  ./local/swbd1_create_fisher_text.sh ./data/fisher/ $fisher_dir_a $fisher_dir_b


  echo ""
  echo creating labels files from fisher...
  echo ""

  python ./local/swbd1_prepare_char_dict_tf.py --text_file ./data/fisher/text --input_units ./data/local/dict_char_lm/units.txt --output_labels $dir_lm/labels.fisher --lm

  echo ""
  echo creating word list from fisher...
  echo ""

  python ./local/swbd1_prepare_word_list_tf.py --text_file ./data/fisher/text --output_word_list $dir_lm/words.fisher --ignore_noises


  echo ""
  echo fusing swbd data with fisher data...
  echo ""

  cat $dir_lm/labels.fisher >> $dir_lm/labels.tr

  echo ""
  echo fusing words files...
  echo ""

  cat $dir_lm/words.fisher > $dir_lm/words
  cat $dir_lm/words.cv >> $dir_lm/words
  cat $dir_lm/words.tr >> $dir_lm/words

  echo ""
  echo training with full swbd text...
  echo ""

  #./steps/train_char_lm.sh --train_dir $dir --nembed $lm_embed_size --nlayer $lm_nlayer --nhidden $lm_ncell_dim --batch_size $lm_batch_size --nepoch 100 --train_labels $dir/labels.tr --cv_labels $dir/labels.cv --drop_out $lm_drop_out --optimizer ${lm_optimizer}

fi

if [ $stage -le 6 ]; then
  echo =====================================================================
  echo "             	Decode Eval 2000 (AM + (char) LM)                  "
  echo =====================================================================

  mkdir -p $dir_lm/results/

  ./steps/decode_ctc_am_char_rnn_tf.sh --lm_config $dir_lm/model/config.pkl --units_file data/local/dict_char_lm/units.txt --results_filename $dir_lm/results/eval2000_result.stm  --lm_weights_ckpt  $dir_lm/model/epoch14.ckpt --lm_config $dir_lm/model/config.pkl --ctc_probs $dir_am/results/epoch09/soft_prob_no_target_name.scp --lexicon_file $dir_lm/words --beam_size 10 --insertion_bonus 0.6 --decoding_strategy greedy_search --blank_scaling 1 --lm_weight 1.5

fi
